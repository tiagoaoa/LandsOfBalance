package session

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"github.com/talves/lands-of-balance/cloud/internal/config"
)

// Manager owns all sessions and enforces the concurrency limit.
type Manager struct {
	cfg *config.Config

	mu       sync.Mutex
	sessions map[string]*Session
	displays map[int]bool
	server   *proc // optional C game_server shared by every instance
	ctx      context.Context
	cancel   context.CancelFunc
}

// NewManager creates the manager and, if asked, the shared game server.
func NewManager(cfg *config.Config) (*Manager, error) {
	ctx, cancel := context.WithCancel(context.Background())
	m := &Manager{cfg: cfg, sessions: map[string]*Session{}, displays: map[int]bool{}, ctx: ctx, cancel: cancel}
	if cfg.RunGameServer {
		if _, err := os.Stat(cfg.GameServerBin); err != nil {
			cancel()
			return nil, fmt.Errorf("game server binary: %w (build it with `make -C %s/server`)", err, cfg.GameDir)
		}
		p, err := startProc("game_server", filepath.Join(cfg.LogDir, "shared"), os.Environ(), cfg.GameServerBin)
		if err != nil {
			cancel()
			return nil, err
		}
		m.server = p
		log.Printf("game_server running (pid %d)", p.Pid())
	}
	go m.reaper()
	return m, nil
}

func newID() string {
	b := make([]byte, 6)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// Create starts a new game instance (asynchronously) and returns it.
func (m *Manager) Create() (*Session, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if len(m.sessions) >= m.cfg.MaxSessions {
		return nil, ErrFull
	}
	num := 0
	if m.cfg.DisplayMode != config.DisplayExisting {
		for n := m.cfg.BaseDisplay; n < m.cfg.BaseDisplay+200; n++ {
			if !m.displays[n] && !displayInUse(n) {
				num = n
				break
			}
		}
		if num == 0 {
			return nil, fmt.Errorf("no free X display number")
		}
		m.displays[num] = true
	}
	s := newSession(m.cfg, newID(), num, m.forget)
	m.sessions[s.ID] = s
	log.Printf("session %s: created (display %d)", s.ID, num)
	go s.start(m.ctx)
	return s, nil
}

// ErrFull is returned when the host has no capacity left.
var ErrFull = fmt.Errorf("all %s slots are busy", "game")

func (m *Manager) forget(s *Session) {
	m.mu.Lock()
	delete(m.sessions, s.ID)
	delete(m.displays, s.displayNum)
	m.mu.Unlock()
	log.Printf("session %s: gone", s.ID)
}

// Get returns a session by id.
func (m *Manager) Get(id string) (*Session, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	s, ok := m.sessions[id]
	return s, ok
}

// List returns all sessions, oldest first.
func (m *Manager) List() []*Session {
	m.mu.Lock()
	out := make([]*Session, 0, len(m.sessions))
	for _, s := range m.sessions {
		out = append(out, s)
	}
	m.mu.Unlock()
	sort.Slice(out, func(i, j int) bool { return out[i].createdAt.Before(out[j].createdAt) })
	return out
}

// Capacity reports used and total slots.
func (m *Manager) Capacity() (used, total int) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.sessions), m.cfg.MaxSessions
}

// reaper closes sessions whose player went silent for too long.
func (m *Manager) reaper() {
	t := time.NewTicker(15 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-m.ctx.Done():
			return
		case <-t.C:
			for _, s := range m.List() {
				in := s.Info()
				if in.State == StateStreaming && s.IdleFor() > m.cfg.IdleTimeout {
					s.Close(fmt.Sprintf("idle for %s", m.cfg.IdleTimeout))
				}
			}
		}
	}
}

// Shutdown closes every session and the shared server.
func (m *Manager) Shutdown() {
	m.cancel()
	var wg sync.WaitGroup
	for _, s := range m.List() {
		wg.Add(1)
		go func(s *Session) { defer wg.Done(); s.Close("gateway shutting down") }(s)
	}
	wg.Wait()
	if m.server != nil {
		m.server.Stop(2 * time.Second)
	}
}
