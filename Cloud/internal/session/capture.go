package session

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/talves/lands-of-balance/cloud/internal/config"
)

// encoder picks the ffmpeg video encoder arguments.
type encoder struct {
	name string
	args []string
}

var detectOnce sync.Once
var detected string

// detectEncoder resolves "auto" to the best encoder ffmpeg can actually use
// on this machine, by trying a one-frame encode with each candidate.
func detectEncoder(cfg *config.Config) string {
	if cfg.Encoder != "auto" {
		return cfg.Encoder
	}
	detectOnce.Do(func() {
		try := func(args ...string) bool {
			argv := append([]string{"-hide_banner", "-loglevel", "error", "-nostdin",
				"-f", "lavfi", "-i", "color=black:s=256x128:r=30:d=0.1"}, args...)
			argv = append(argv, "-frames:v", "2", "-f", "null", "-")
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			return exec.CommandContext(ctx, "ffmpeg", argv...).Run() == nil
		}
		switch {
		case try("-pix_fmt", "yuv420p", "-c:v", "h264_nvenc"):
			detected = "nvenc"
		case try("-vaapi_device", cfg.VaapiDevice, "-vf", "format=nv12,hwupload", "-c:v", "h264_vaapi"):
			detected = "vaapi"
		default:
			detected = "x264"
		}
		log.Printf("encoder: auto → %s", detected)
	})
	return detected
}

func (c *capture) videoEncoder(cfg *config.Config) encoder {
	kb := strconv.Itoa(cfg.BitrateKbps) + "k"
	buf := strconv.Itoa(cfg.BitrateKbps/2) + "k" // half a second of buffer at most
	// Periodic IDR keyframes (one per second) rather than a single IDR + a
	// lifelong intra-refresh wave. ffmpeg has no back-channel, so it cannot
	// answer a browser PLI with an on-demand keyframe; without regular IDRs a
	// single lost packet at, say, the class→world transition corrupts the
	// reference chain forever and the picture freezes on the last good frame.
	// A 1 s keyframe interval lets the decoder re-sync within a second of any
	// loss — the standard trade for a browser-facing, possibly-lossy path.
	gop := strconv.Itoa(cfg.FPS)
	profile := cfg.H264Profile
	switch detectEncoder(cfg) {
	case "nvenc":
		return encoder{"nvenc", []string{
			"-vf", c.vf("format=yuv420p"),
			"-c:v", "h264_nvenc", "-preset", "p1", "-tune", "ull",
			"-zerolatency", "1", "-delay", "0", "-bf", "0", "-rc", "cbr",
			"-b:v", kb, "-maxrate", kb, "-bufsize", buf,
			"-g", gop, "-forced-idr", "1", "-no-scenecut", "1",
			"-profile:v", profile}}
	case "vaapi":
		// vaapi profiles: constrained_baseline | main | high
		if profile == "baseline" {
			profile = "constrained_baseline"
		}
		return encoder{"vaapi", []string{
			"-vf", c.vf("format=nv12,hwupload"),
			"-c:v", "h264_vaapi", "-rc_mode", "CBR", "-async_depth", "1",
			"-b:v", kb, "-maxrate", kb, "-bufsize", buf,
			"-g", gop, "-bf", "0", "-idr_interval", "0",
			"-profile:v", profile}}
	default:
		return encoder{"x264", []string{
			"-vf", c.vf("format=yuv420p"),
			"-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
			"-b:v", kb, "-maxrate", kb, "-bufsize", buf,
			"-g", gop, "-keyint_min", gop, "-bf", "0", "-threads", "4",
			"-x264-params", "scenecut=0:rc-lookahead=0:sync-lookahead=0:sliced-threads=1:nal-hrd=cbr:force-cfr=1:aud=0",
			"-profile:v", profile}}
	}
}

// vf prefixes the encoder's pixel-format filter with an even-size clamp when
// grabbing a window whose size we did not choose.
func (c *capture) vf(tail string) string {
	if c.windowID != "" {
		return "scale=trunc(iw/2)*2:trunc(ih/2)*2:flags=fast_bilinear," + tail
	}
	return tail
}

// capture is the ffmpeg pair (video, audio) that turns a display into RTP.
type capture struct {
	cfg      *config.Config
	logDir   string
	display  string
	windowID string
	monitor  string
	videoRTP string // 127.0.0.1:port
	audioRTP string

	mu    sync.Mutex
	video *proc
	audio *proc
	stop  chan struct{}
}

func (c *capture) videoArgv() []string {
	argv := []string{"ffmpeg", "-hide_banner", "-loglevel", "warning", "-nostdin",
		"-fflags", "nobuffer", "-flags", "low_delay", "-probesize", "32", "-analyzeduration", "0",
		"-thread_queue_size", "64",
		"-f", "x11grab", "-draw_mouse", "0", "-framerate", strconv.Itoa(c.cfg.FPS)}
	if c.windowID != "" {
		argv = append(argv, "-window_id", c.windowID)
	} else {
		argv = append(argv, "-video_size", fmt.Sprintf("%dx%d", c.cfg.Width, c.cfg.Height))
	}
	argv = append(argv, "-i", c.display+"+0,0")
	argv = append(argv, c.videoEncoder(c.cfg).args...)
	argv = append(argv,
		"-an", "-max_delay", "0", "-flush_packets", "1",
		"-f", "rtp", "-payload_type", "102", "rtp://"+c.videoRTP+"?pkt_size=1200")
	return argv
}

func (c *capture) audioArgv() []string {
	return []string{"ffmpeg", "-hide_banner", "-loglevel", "warning", "-nostdin",
		"-fflags", "nobuffer", "-flags", "low_delay",
		"-f", "pulse", "-fragment_size", "1920", "-i", c.monitor,
		"-ac", "2", "-ar", "48000",
		"-c:a", "libopus", "-b:a", strconv.Itoa(c.cfg.AudioKbps) + "k",
		"-application", "lowdelay", "-frame_duration", "10", "-fec:a", "1", "-packet_loss:a", "5",
		"-vn", "-max_delay", "0", "-flush_packets", "1",
		"-f", "rtp", "-payload_type", "111", "rtp://" + c.audioRTP}
}

// start launches both ffmpeg processes and babysits them: a crash restarts
// the stream (with backoff) until stop() is called.
func (c *capture) start() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.stop != nil {
		return
	}
	c.stop = make(chan struct{})
	go c.supervise("ffmpeg-video", c.videoArgv, func(p *proc) { c.mu.Lock(); c.video = p; c.mu.Unlock() })
	if c.monitor != "" {
		go c.supervise("ffmpeg-audio", c.audioArgv, func(p *proc) { c.mu.Lock(); c.audio = p; c.mu.Unlock() })
	}
}

func (c *capture) supervise(name string, argv func() []string, set func(*proc)) {
	stop := c.stop
	backoff := 500 * time.Millisecond
	for attempt := 0; ; attempt++ {
		select {
		case <-stop:
			return
		default:
		}
		env := append(os.Environ(), "DISPLAY="+c.display)
		p, err := startProc(name, c.logDir, env, argv()...)
		if err != nil {
			log.Printf("%s: %v", name, err)
			return
		}
		set(p)
		started := time.Now()
		select {
		case <-stop:
			p.Stop(time.Second)
			return
		case <-p.Done():
		}
		_, werr := p.Exited()
		log.Printf("%s exited after %s: %v — %s", name, time.Since(started).Round(time.Millisecond), werr,
			strings.TrimSpace(lastLine(tailLog(c.logDir, name, 400))))
		if time.Since(started) > 10*time.Second {
			backoff = 500 * time.Millisecond
		} else if backoff < 8*time.Second {
			backoff *= 2
		}
		if attempt > 20 && time.Since(started) < 10*time.Second {
			log.Printf("%s: giving up after %d crashes", name, attempt)
			return
		}
		select {
		case <-stop:
			return
		case <-time.After(backoff):
		}
	}
}

func (c *capture) halt() {
	c.mu.Lock()
	stop := c.stop
	c.stop = nil
	v, a := c.video, c.audio
	c.video, c.audio = nil, nil
	c.mu.Unlock()
	if stop != nil {
		close(stop)
	}
	v.Stop(time.Second)
	a.Stop(time.Second)
}

func lastLine(s string) string {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		if l := strings.TrimSpace(lines[i]); l != "" && !strings.HasPrefix(l, "====") {
			return l
		}
	}
	return ""
}
