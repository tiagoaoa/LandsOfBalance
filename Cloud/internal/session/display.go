package session

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/talves/lands-of-balance/cloud/internal/config"
)

// display is the display server a game instance renders into: an X server,
// or in weston mode a headless Wayland compositor.
type display struct {
	mode       config.DisplayMode
	name       string // ":101", the inherited $DISPLAY, or the wayland socket
	num        int
	virtual    bool
	wayland    bool
	runtimeDir string // XDG_RUNTIME_DIR owning the wayland socket
	proc       *proc
}

// startDisplay brings up the X display for a session. In `existing` mode it
// just returns the current $DISPLAY.
func startDisplay(ctx context.Context, cfg *config.Config, num int, logDir string) (*display, error) {
	d := &display{mode: cfg.DisplayMode, num: num}
	switch cfg.DisplayMode {
	case config.DisplayExisting:
		d.name = os.Getenv("DISPLAY")
		return d, nil
	case config.DisplayXvfb:
		d.name = fmt.Sprintf(":%d", num)
		d.virtual = true
		argv := []string{"Xvfb", d.name,
			"-screen", "0", fmt.Sprintf("%dx%dx24", cfg.Width, cfg.Height),
			"+extension", "GLX", "+extension", "RANDR", "+render",
			"-nolisten", "tcp", "-noreset", "-ac", "-dpi", "96"}
		p, err := startProc("xvfb", logDir, os.Environ(), argv...)
		if err != nil {
			return nil, err
		}
		d.proc = p
	case config.DisplayWeston:
		d.wayland = true
		d.virtual = true
		d.name = fmt.Sprintf("lob-wl-%d", num)
		d.runtimeDir = filepath.Join(logDir, "xdg")
		if err := os.MkdirAll(d.runtimeDir, 0o700); err != nil {
			return nil, err
		}
		env := append(os.Environ(), "XDG_RUNTIME_DIR="+d.runtimeDir)
		argv := []string{"weston",
			"--backend=headless-backend.so",
			"--width=" + strconv.Itoa(cfg.Width), "--height=" + strconv.Itoa(cfg.Height),
			"--socket=" + d.name, "--idle-time=0"}
		if cfg.WestonGL {
			// The GL renderer makes weston advertise linux-dmabuf, which is
			// what NVIDIA's Vulkan needs before it will present on Wayland.
			argv = append(argv, "--use-gl")
		}
		p, err := startProc("weston", logDir, env, argv...)
		if err != nil {
			return nil, err
		}
		d.proc = p
	case config.DisplayXorg:
		d.name = fmt.Sprintf(":%d", num)
		d.virtual = true
		argv := []string{"Xorg", d.name, "-config", cfg.XorgConfig,
			"-noreset", "-nolisten", "tcp", "-ac", "-novtswitch", "-sharevts",
			"-logfile", logDir + "/xorg.server.log"}
		p, err := startProc("xorg", logDir, os.Environ(), argv...)
		if err != nil {
			return nil, err
		}
		d.proc = p
	}
	if err := d.waitReady(ctx); err != nil {
		d.stop()
		return nil, err
	}
	if cfg.DisplayMode == config.DisplayXorg {
		// Headless Xorg starts at whatever the config says; pin the mode.
		_ = exec.Command("xrandr", "-d", d.name, "-s", fmt.Sprintf("%dx%d", cfg.Width, cfg.Height)).Run()
	}
	return d, nil
}

// waitReady polls until the display server accepts connections.
func (d *display) waitReady(ctx context.Context) error {
	if d.wayland {
		deadline := time.Now().Add(15 * time.Second)
		sock := filepath.Join(d.runtimeDir, d.name)
		for time.Now().Before(deadline) {
			if ex, err := d.proc.Exited(); ex {
				return fmt.Errorf("weston died: %v", err)
			}
			if _, err := os.Stat(sock); err == nil {
				return nil
			}
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(100 * time.Millisecond):
			}
		}
		return fmt.Errorf("weston socket %s not ready after 15s", sock)
	}
	sock := fmt.Sprintf("/tmp/.X11-unix/X%d", d.num)
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		if ex, err := d.proc.Exited(); ex {
			return fmt.Errorf("X server died: %v", err)
		}
		if _, err := os.Stat(sock); err == nil {
			// xdpyinfo is the cheapest "is it really answering" probe.
			if err := exec.Command("xdpyinfo", "-display", d.name).Run(); err == nil {
				return nil
			}
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(100 * time.Millisecond):
		}
	}
	return fmt.Errorf("X server %s not ready after 15s", d.name)
}

func (d *display) stop() {
	if d == nil || d.proc == nil {
		return
	}
	d.proc.Stop(2 * time.Second)
}

// displayInUse reports whether an X server already owns a display number.
func displayInUse(num int) bool {
	if _, err := os.Stat(fmt.Sprintf("/tmp/.X%d-lock", num)); err == nil {
		return true
	}
	if _, err := os.Stat(fmt.Sprintf("/tmp/.X11-unix/X%d", num)); err == nil {
		return true
	}
	return false
}

// findWindow returns the X window id of a process' top-level window, by
// polling xdotool. Used in `existing` mode to grab only the game window.
func findWindow(ctx context.Context, disp string, pid int) (string, error) {
	env := append(os.Environ(), "DISPLAY="+disp)
	for {
		cmd := exec.Command("xdotool", "search", "--onlyvisible", "--pid", strconv.Itoa(pid))
		cmd.Env = env
		out, err := cmd.Output()
		if err == nil {
			for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
				if line = strings.TrimSpace(line); line != "" {
					return line, nil
				}
			}
		}
		select {
		case <-ctx.Done():
			return "", fmt.Errorf("game window not found: %w", ctx.Err())
		case <-time.After(250 * time.Millisecond):
		}
	}
}
