// Package config holds the runtime configuration of the cloud gateway.
//
// Everything is a flag with an LOB_* environment fallback so the same binary
// runs from a shell, a systemd unit or a container without a config file.
package config

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// DisplayMode selects how a session gets an X display to render into.
type DisplayMode string

const (
	// DisplayExisting renders into the display already named by $DISPLAY
	// (the developer's desktop). The game runs windowed and the capture
	// grabs that window only. No privileges needed, nothing virtual.
	DisplayExisting DisplayMode = "existing"
	// DisplayXvfb starts one Xvfb per session. Rendering is done by Mesa
	// (RADV/ANV hardware via the software WSI path, or lavapipe on CPU).
	DisplayXvfb DisplayMode = "xvfb"
	// DisplayXorg starts one real Xorg server per session from an xorg.conf
	// (the NVIDIA headless setup). Needs the nvidia X driver and usually
	// root or a suid Xorg.
	DisplayXorg DisplayMode = "xorg"
)

// Config is the full gateway configuration.
type Config struct {
	Listen  string
	WebDir  string
	LogDir  string
	Token   string
	Verbose bool

	// Game process.
	GodotBin  string
	GameDir   string
	GameArgs  []string
	GameEnv   []string
	GameServerBin string // optional: start the C game_server once for all sessions
	RunGameServer bool

	// Display.
	DisplayMode DisplayMode
	XorgConfig  string
	BaseDisplay int
	Width       int
	Height      int
	FPS         int

	// Encoding.
	Encoder      string // auto | nvenc | vaapi | x264
	VaapiDevice  string
	BitrateKbps  int
	AudioKbps    int
	H264Profile  string
	Audio        bool

	// Sessions.
	MaxSessions    int
	IdleTimeout    time.Duration
	ReconnectGrace time.Duration
	StartTimeout   time.Duration

	// WebRTC.
	PublicIP   string
	UDPPortMin int
	UDPPortMax int
	ICEServers []string // stun:host:port | turn:user:pass@host:port[?transport=tcp]
}

func envOr(key, def string) string {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		return v
	}
	return def
}

func envInt(key string, def int) int {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

func envBool(key string, def bool) bool {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		switch strings.ToLower(v) {
		case "1", "true", "yes", "on":
			return true
		case "0", "false", "no", "off":
			return false
		}
	}
	return def
}

func envDur(key string, def time.Duration) time.Duration {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
	}
	return def
}

// Parse reads flags (with LOB_* env defaults) and validates them.
func Parse(args []string) (*Config, error) {
	c := &Config{}
	fs := flag.NewFlagSet("lobcloud", flag.ContinueOnError)

	exe, _ := os.Executable()
	defaultWeb := filepath.Join(filepath.Dir(exe), "web")
	if _, err := os.Stat(defaultWeb); err != nil {
		defaultWeb = "web"
	}
	// Empty is meaningful here ("no --path, the binary is an exported
	// game"), so look the variable up instead of treating "" as unset.
	defaultGame := ".."
	if v, ok := os.LookupEnv("LOB_GAME_DIR"); ok {
		defaultGame = v
	}

	var gameArgs, gameEnv, ice string

	fs.StringVar(&c.Listen, "listen", envOr("LOB_LISTEN", ":8080"), "HTTP listen address")
	fs.StringVar(&c.WebDir, "web", envOr("LOB_WEB_DIR", defaultWeb), "directory with the browser client")
	fs.StringVar(&c.LogDir, "log-dir", envOr("LOB_LOG_DIR", filepath.Join(os.TempDir(), "lobcloud")), "per-session process logs")
	fs.StringVar(&c.Token, "token", envOr("LOB_TOKEN", ""), "shared secret required to create sessions (empty = open)")
	fs.BoolVar(&c.Verbose, "v", envBool("LOB_VERBOSE", false), "verbose logging")

	fs.StringVar(&c.GodotBin, "godot", envOr("LOB_GODOT", "godot"), "Godot binary (editor binary or exported game)")
	fs.StringVar(&c.GameDir, "game-dir", defaultGame, "Godot project dir (passed as --path); empty when --godot is an exported game")
	fs.StringVar(&gameArgs, "game-args", envOr("LOB_GAME_ARGS", ""), "extra args for the game, space separated (default: --singleplayer unless --game-server)")
	fs.StringVar(&gameEnv, "game-env", envOr("LOB_GAME_ENV", ""), "extra KEY=VALUE env for the game, comma separated")
	fs.BoolVar(&c.RunGameServer, "game-server", envBool("LOB_GAME_SERVER", false), "also start the C multiplayer game_server so sessions share a world")
	fs.StringVar(&c.GameServerBin, "game-server-bin", envOr("LOB_GAME_SERVER_BIN", ""), "path to server/game_server (default <game-dir>/server/game_server)")

	fs.StringVar((*string)(&c.DisplayMode), "display-mode", envOr("LOB_DISPLAY_MODE", string(DisplayExisting)), "existing | xvfb | xorg")
	fs.StringVar(&c.XorgConfig, "xorg-config", envOr("LOB_XORG_CONFIG", ""), "xorg.conf for --display-mode xorg")
	fs.IntVar(&c.BaseDisplay, "base-display", envInt("LOB_BASE_DISPLAY", 100), "first X display number for virtual displays")
	fs.IntVar(&c.Width, "width", envInt("LOB_WIDTH", 1280), "stream width")
	fs.IntVar(&c.Height, "height", envInt("LOB_HEIGHT", 720), "stream height")
	fs.IntVar(&c.FPS, "fps", envInt("LOB_FPS", 60), "stream frame rate")

	fs.StringVar(&c.Encoder, "encoder", envOr("LOB_ENCODER", "auto"), "auto | nvenc | vaapi | x264")
	fs.StringVar(&c.VaapiDevice, "vaapi-device", envOr("LOB_VAAPI_DEVICE", "/dev/dri/renderD128"), "DRM render node for vaapi")
	fs.IntVar(&c.BitrateKbps, "bitrate", envInt("LOB_BITRATE", 8000), "video bitrate in kbit/s")
	fs.IntVar(&c.AudioKbps, "audio-bitrate", envInt("LOB_AUDIO_BITRATE", 96), "opus bitrate in kbit/s")
	fs.StringVar(&c.H264Profile, "h264-profile", envOr("LOB_H264_PROFILE", "baseline"), "baseline | main | high")
	fs.BoolVar(&c.Audio, "audio", envBool("LOB_AUDIO", true), "capture game audio through a PulseAudio null sink")

	fs.IntVar(&c.MaxSessions, "max-sessions", envInt("LOB_MAX_SESSIONS", 2), "maximum concurrent game instances")
	fs.DurationVar(&c.IdleTimeout, "idle-timeout", envDur("LOB_IDLE_TIMEOUT", 10*time.Minute), "kill a session after this long without input")
	fs.DurationVar(&c.ReconnectGrace, "reconnect-grace", envDur("LOB_RECONNECT_GRACE", 90*time.Second), "keep the game alive this long after the player disconnects")
	fs.DurationVar(&c.StartTimeout, "start-timeout", envDur("LOB_START_TIMEOUT", 90*time.Second), "give up if the game is not accepting input by then")

	fs.StringVar(&c.PublicIP, "public-ip", envOr("LOB_PUBLIC_IP", ""), "public IP to advertise in ICE candidates (behind 1:1 NAT)")
	fs.IntVar(&c.UDPPortMin, "udp-min", envInt("LOB_UDP_MIN", 0), "lowest UDP port for WebRTC media (0 = ephemeral)")
	fs.IntVar(&c.UDPPortMax, "udp-max", envInt("LOB_UDP_MAX", 0), "highest UDP port for WebRTC media")
	fs.StringVar(&ice, "ice", envOr("LOB_ICE", "stun:stun.l.google.com:19302"), "comma separated ICE servers: stun:host:port, turn:user:pass@host:port")

	if err := fs.Parse(args); err != nil {
		return nil, err
	}

	if gameArgs != "" {
		c.GameArgs = strings.Fields(gameArgs)
	} else if !c.RunGameServer {
		c.GameArgs = []string{"--singleplayer"}
	}
	if gameEnv != "" {
		for _, kv := range strings.Split(gameEnv, ",") {
			if kv = strings.TrimSpace(kv); kv != "" {
				c.GameEnv = append(c.GameEnv, kv)
			}
		}
	}
	if ice != "" {
		for _, s := range strings.Split(ice, ",") {
			if s = strings.TrimSpace(s); s != "" {
				c.ICEServers = append(c.ICEServers, s)
			}
		}
	}
	if c.GameServerBin == "" && c.GameDir != "" {
		c.GameServerBin = filepath.Join(c.GameDir, "server", "game_server")
	}

	switch c.DisplayMode {
	case DisplayExisting, DisplayXvfb, DisplayXorg:
	default:
		return nil, fmt.Errorf("bad --display-mode %q", c.DisplayMode)
	}
	if c.DisplayMode == DisplayExisting && os.Getenv("DISPLAY") == "" {
		return nil, fmt.Errorf("--display-mode existing needs $DISPLAY")
	}
	if c.DisplayMode == DisplayXorg && c.XorgConfig == "" {
		return nil, fmt.Errorf("--display-mode xorg needs --xorg-config")
	}
	if c.Width%2 != 0 || c.Height%2 != 0 {
		return nil, fmt.Errorf("width and height must be even (got %dx%d)", c.Width, c.Height)
	}
	if c.FPS < 10 || c.FPS > 120 {
		return nil, fmt.Errorf("fps out of range: %d", c.FPS)
	}
	if (c.UDPPortMin == 0) != (c.UDPPortMax == 0) || c.UDPPortMin > c.UDPPortMax {
		return nil, fmt.Errorf("bad udp port range %d-%d", c.UDPPortMin, c.UDPPortMax)
	}
	switch c.Encoder {
	case "auto", "nvenc", "vaapi", "x264":
	default:
		return nil, fmt.Errorf("bad --encoder %q", c.Encoder)
	}
	if c.GameDir != "" {
		abs, err := filepath.Abs(c.GameDir)
		if err == nil {
			c.GameDir = abs
		}
	}
	return c, nil
}
