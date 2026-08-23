package session

import (
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"net"
	"sync"
	"time"
)

// frameBridge receives raw RGBA frames from the game's CloudFrames autoload
// over loopback TCP and hands them, whole frames at a time, to whichever
// ffmpeg is currently encoding. Switching sinks only at frame boundaries is
// the point: an encoder that joins mid-frame decodes shifted garbage forever.
type frameBridge struct {
	ln  net.Listener
	fps int // forward at most this many frames per second downstream

	mu     sync.Mutex
	sink   io.WriteCloser
	width  int
	height int
	pixfmt string // ffmpeg name: rgba | rgb24

	ready  chan struct{} // closed once the header told us the geometry
	closed chan struct{}
}

func newFrameBridge(fps int) (*frameBridge, error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	b := &frameBridge{ln: ln, fps: fps, ready: make(chan struct{}), closed: make(chan struct{})}
	go b.accept()
	return b, nil
}

func (b *frameBridge) Port() int { return b.ln.Addr().(*net.TCPAddr).Port }

// Geometry blocks until the game has announced its frame layout.
func (b *frameBridge) Geometry(timeout time.Duration) (w, h int, pixfmt string, err error) {
	select {
	case <-b.ready:
		b.mu.Lock()
		defer b.mu.Unlock()
		return b.width, b.height, b.pixfmt, nil
	case <-b.closed:
		return 0, 0, "", fmt.Errorf("frame bridge closed")
	case <-time.After(timeout):
		return 0, 0, "", fmt.Errorf("game sent no frames within %s", timeout)
	}
}

// SetSink routes subsequent frames into w (nil = drop them).
func (b *frameBridge) SetSink(w io.WriteCloser) {
	b.mu.Lock()
	b.sink = w
	b.mu.Unlock()
}

func (b *frameBridge) accept() {
	for {
		conn, err := b.ln.Accept()
		if err != nil {
			return // listener closed
		}
		log.Printf("frame bridge: game connected")
		// One producer at a time; a reconnecting game replaces itself.
		b.serve(conn)
	}
}

func (b *frameBridge) serve(conn net.Conn) {
	defer conn.Close()
	hdr := make([]byte, 16)
	if _, err := io.ReadFull(conn, hdr); err != nil {
		return
	}
	if string(hdr[:4]) != "LOBF" {
		log.Printf("frame bridge: bad magic %q", hdr[:4])
		return
	}
	w := int(binary.LittleEndian.Uint32(hdr[4:]))
	h := int(binary.LittleEndian.Uint32(hdr[8:]))
	bpp, pixfmt := 4, "rgba"
	if string(hdr[12:16]) == "RGB8" {
		bpp, pixfmt = 3, "rgb24"
	}
	if w < 16 || h < 16 || w > 7680 || h > 4320 {
		log.Printf("frame bridge: absurd geometry %dx%d", w, h)
		return
	}
	b.mu.Lock()
	first := b.width == 0
	b.width, b.height, b.pixfmt = w, h, pixfmt
	b.mu.Unlock()
	if first {
		close(b.ready)
		log.Printf("frame bridge: game streaming %dx%d %s", w, h, pixfmt)
	}
	// The game ships every frame it renders — 100+ fps in a menu — and the
	// encoder, fed wallclock timestamps, would happily bill you for all of
	// them. Forward at most the configured rate; surplus frames are read
	// and discarded, which also keeps the game's writer from blocking.
	minGap := time.Duration(0)
	if b.fps > 0 {
		minGap = time.Second / time.Duration(b.fps) * 9 / 10
	}
	if tc, ok := conn.(*net.TCPConn); ok {
		// Cap in-flight bytes: whatever the encoder has not consumed sits
		// in socket buffers as standing latency. One frame of window is
		// enough for full throughput on loopback.
		_ = tc.SetReadBuffer(w * h * bpp)
	}
	var lastFwd time.Time
	inN, fwdN := 0, 0
	statT := time.Now()
	frame := make([]byte, w*h*bpp)
	for {
		if _, err := io.ReadFull(conn, frame); err != nil {
			return
		}
		inN++
		if time.Since(statT) >= 5*time.Second {
			sec := time.Since(statT).Seconds()
			log.Printf("frame bridge: game %.1f fps in, %.1f fps to encoder", float64(inN)/sec, float64(fwdN)/sec)
			inN, fwdN = 0, 0
			statT = time.Now()
		}
		if time.Since(lastFwd) < minGap {
			continue
		}
		b.mu.Lock()
		sink := b.sink
		b.mu.Unlock()
		if sink != nil {
			lastFwd = time.Now()
			fwdN++
			if _, err := sink.Write(frame); err != nil {
				// Encoder went away mid-frame; drop the sink, the
				// supervisor will hand us a fresh one.
				b.SetSink(nil)
			}
		}
	}
}

func (b *frameBridge) stop() {
	if b == nil {
		return
	}
	select {
	case <-b.closed:
	default:
		close(b.closed)
	}
	b.ln.Close()
}
