package session

import (
	"context"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"syscall"
	"time"
)

// proc is a child process in its own process group with its output tee'd to
// a log file, so a session can be torn down by killing the group and the
// last lines of every helper survive for debugging.
type proc struct {
	name string
	cmd  *exec.Cmd
	log  *os.File

	mu     sync.Mutex
	done   chan struct{}
	err    error
	exited bool
}

func startProc(name, logDir string, env []string, argv ...string) (*proc, error) {
	if len(argv) == 0 {
		return nil, fmt.Errorf("%s: empty command", name)
	}
	if err := os.MkdirAll(logDir, 0o755); err != nil {
		return nil, err
	}
	lf, err := os.OpenFile(filepath.Join(logDir, name+".log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return nil, err
	}
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Env = env
	cmd.Stdout = lf
	cmd.Stderr = lf
	cmd.Stdin = nil
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	fmt.Fprintf(lf, "\n==== %s: %v\n", time.Now().Format(time.RFC3339), argv)
	if err := cmd.Start(); err != nil {
		lf.Close()
		return nil, fmt.Errorf("%s: %w", name, err)
	}
	p := &proc{name: name, cmd: cmd, log: lf, done: make(chan struct{})}
	go func() {
		err := cmd.Wait()
		p.mu.Lock()
		p.err = err
		p.exited = true
		p.mu.Unlock()
		fmt.Fprintf(lf, "==== exited: %v\n", err)
		lf.Close()
		close(p.done)
	}()
	return p, nil
}

// Done is closed when the process has exited.
func (p *proc) Done() <-chan struct{} { return p.done }

// Exited reports whether the process is gone and its exit error.
func (p *proc) Exited() (bool, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.exited, p.err
}

// Stop sends SIGTERM to the group, then SIGKILL after the grace period.
func (p *proc) Stop(grace time.Duration) {
	if p == nil {
		return
	}
	if ex, _ := p.Exited(); ex {
		return
	}
	pgid := -p.cmd.Process.Pid
	_ = syscall.Kill(pgid, syscall.SIGTERM)
	select {
	case <-p.done:
		return
	case <-time.After(grace):
	}
	_ = syscall.Kill(pgid, syscall.SIGKILL)
	select {
	case <-p.done:
	case <-time.After(2 * time.Second):
		log.Printf("%s: did not die after SIGKILL", p.name)
	}
}

// Pid returns the process id.
func (p *proc) Pid() int { return p.cmd.Process.Pid }

// tailLog returns the last n bytes of a process log, for error messages.
func tailLog(logDir, name string, n int64) string {
	f, err := os.Open(filepath.Join(logDir, name+".log"))
	if err != nil {
		return ""
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return ""
	}
	off := st.Size() - n
	if off < 0 {
		off = 0
	}
	b, _ := io.ReadAll(io.NewSectionReader(f, off, n))
	return string(b)
}

// waitCtx waits for a channel or the context.
func waitCtx(ctx context.Context, ch <-chan struct{}) error {
	select {
	case <-ch:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}
