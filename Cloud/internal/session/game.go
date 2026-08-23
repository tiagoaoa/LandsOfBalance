package session

import (
	"context"
	"fmt"
	"net"
	"os"
	"strconv"
	"sync"
	"time"

	"github.com/talves/lands-of-balance/cloud/internal/config"
	"github.com/talves/lands-of-balance/cloud/internal/proto"
)

// game is one Godot instance plus the TCP link to its CloudInput autoload.
type game struct {
	proc      *proc
	inputPort int

	mu   sync.Mutex
	conn net.Conn
	// onGameFrame receives frames the game sends back (mouse mode etc.).
	onGameFrame func([]byte)
}

// freeTCPPort asks the kernel for an unused loopback port.
func freeTCPPort() (int, error) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port, nil
}

func startGame(cfg *config.Config, d *display, sink *audioSink, logDir string) (*game, error) {
	port, err := freeTCPPort()
	if err != nil {
		return nil, err
	}
	argv := []string{cfg.GodotBin}
	if cfg.GameDir != "" {
		argv = append(argv, "--path", cfg.GameDir)
	}
	argv = append(argv,
		"--resolution", fmt.Sprintf("%dx%d", cfg.Width, cfg.Height),
		"--position", "0,0",
		"--single-window")
	if d.virtual {
		// No window manager on a virtual display: nothing to decorate and
		// nothing to steal focus. Always-on-top is harmless there.
		argv = append(argv, "--always-on-top")
	}
	argv = append(argv, cfg.GameArgs...)

	env := append([]string{}, os.Environ()...)
	env = append(env,
		"DISPLAY="+d.name,
		"LOB_CLOUD_INPUT_PORT="+strconv.Itoa(port),
		"LOB_CLOUD=1",
		// The MCP runtime autoload binds a fixed port; two sessions would clash.
		"GODOT_MCP_RUNTIME_ENABLED=0",
	)
	if sink != nil {
		env = append(env, "PULSE_SINK="+sink.name)
	}
	if d.virtual {
		// Mesa Vulkan drivers need DRI3 to present on X; Xvfb has none.
		// The software WSI path copies the frame through the CPU instead,
		// which is exactly what a capture pipeline wants anyway.
		if os.Getenv("MESA_VK_WSI_DEBUG") == "" {
			env = append(env, "MESA_VK_WSI_DEBUG=sw")
		}
	}
	env = append(env, cfg.GameEnv...)

	p, err := startProc("godot", logDir, env, argv...)
	if err != nil {
		return nil, err
	}
	return &game{proc: p, inputPort: port}, nil
}

// waitInput connects to the game's input port, retrying until the autoload
// is listening or the game dies.
func (g *game) waitInput(ctx context.Context) error {
	addr := "127.0.0.1:" + strconv.Itoa(g.inputPort)
	for {
		if ex, err := g.proc.Exited(); ex {
			return fmt.Errorf("game exited during startup: %v", err)
		}
		c, err := net.DialTimeout("tcp", addr, 500*time.Millisecond)
		if err == nil {
			g.mu.Lock()
			g.conn = c
			g.mu.Unlock()
			go g.readLoop(c)
			return nil
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("game input port %d never opened: %w", g.inputPort, ctx.Err())
		case <-time.After(300 * time.Millisecond):
		}
	}
}

// readLoop forwards frames coming back from the game.
func (g *game) readLoop(c net.Conn) {
	buf := make([]byte, 0, 256)
	tmp := make([]byte, 256)
	for {
		n, err := c.Read(tmp)
		if err != nil {
			return
		}
		buf = append(buf, tmp[:n]...)
		for {
			l, err := proto.FrameLen(buf)
			if err != nil || l == 0 || l > len(buf) {
				if err != nil {
					buf = buf[:0] // desync; drop and resync on next bytes
				}
				break
			}
			g.mu.Lock()
			cb := g.onGameFrame
			g.mu.Unlock()
			if cb != nil {
				cb(append([]byte{}, buf[:l]...))
			}
			buf = buf[l:]
		}
	}
}

// sendInput writes validated client frames to the game.
func (g *game) sendInput(b []byte) error {
	g.mu.Lock()
	c := g.conn
	g.mu.Unlock()
	if c == nil {
		return fmt.Errorf("game input not connected")
	}
	_ = c.SetWriteDeadline(time.Now().Add(200 * time.Millisecond))
	_, err := c.Write(b)
	return err
}

func (g *game) releaseAll() { _ = g.sendInput([]byte{proto.ReleaseAllFrame}) }

func (g *game) stop() {
	if g == nil {
		return
	}
	g.mu.Lock()
	if g.conn != nil {
		g.conn.Close()
		g.conn = nil
	}
	g.mu.Unlock()
	g.proc.Stop(3 * time.Second)
}
