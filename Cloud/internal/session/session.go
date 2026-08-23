// Package session runs game instances: one X display, one audio sink, one
// Godot process and one capture pipeline per player, plus the glue to the
// WebRTC peer that is currently driving it.
package session

import (
	"context"
	"fmt"
	"log"
	"path/filepath"
	"sync"
	"time"

	"github.com/talves/lands-of-balance/cloud/internal/config"
	"github.com/talves/lands-of-balance/cloud/internal/proto"
	"github.com/talves/lands-of-balance/cloud/internal/rtc"
)

// State is the lifecycle phase of a session.
type State string

const (
	StateStarting  State = "starting"  // display / game booting
	StateReady     State = "ready"     // game accepts input, no player attached
	StateStreaming State = "streaming" // player connected, ffmpeg running
	StateWaiting   State = "waiting"   // player dropped, game kept for reconnect
	StateStopped   State = "stopped"   // torn down (game quit, idle, deleted)
	StateError     State = "error"     // could not start
)

// Info is the JSON view of a session.
type Info struct {
	ID        string    `json:"id"`
	State     State     `json:"state"`
	Error     string    `json:"error,omitempty"`
	CreatedAt time.Time `json:"createdAt"`
	Display   string    `json:"display"`
	Encoder   string    `json:"encoder"`
	Width     int       `json:"width"`
	Height    int       `json:"height"`
	FPS       int       `json:"fps"`
	Peer      bool      `json:"peerConnected"`
	LastInput time.Time `json:"lastInput"`
}

// Session is one running game instance.
type Session struct {
	ID  string
	cfg *config.Config

	logDir     string
	displayNum int
	createdAt  time.Time

	mu        sync.Mutex
	state     State
	errMsg    string
	display   *display
	sink      *audioSink
	game      *game
	bridge    *frameBridge
	cap       *capture
	peer      *rtc.Peer
	lastInput time.Time
	grace     *time.Timer
	subs      map[int]func(Info)
	nextSub   int
	closed    bool
	onClosed  func(*Session)
}

func newSession(cfg *config.Config, id string, displayNum int, onClosed func(*Session)) *Session {
	return &Session{
		ID:         id,
		cfg:        cfg,
		logDir:     filepath.Join(cfg.LogDir, id),
		displayNum: displayNum,
		createdAt:  time.Now(),
		state:      StateStarting,
		lastInput:  time.Now(),
		subs:       map[int]func(Info){},
		onClosed:   onClosed,
	}
}

// LogDir is where this session's process logs live.
func (s *Session) LogDir() string { return s.logDir }

// Info snapshots the session.
func (s *Session) Info() Info {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.infoLocked()
}

func (s *Session) infoLocked() Info {
	in := Info{ID: s.ID, State: s.state, Error: s.errMsg, CreatedAt: s.createdAt,
		Width: s.cfg.Width, Height: s.cfg.Height, FPS: s.cfg.FPS,
		Peer: s.peer != nil, LastInput: s.lastInput, Encoder: detectEncoder(s.cfg)}
	if s.display != nil {
		in.Display = s.display.name
	}
	return in
}

// Subscribe registers a state listener; the returned func removes it.
func (s *Session) Subscribe(fn func(Info)) func() {
	s.mu.Lock()
	id := s.nextSub
	s.nextSub++
	s.subs[id] = fn
	in := s.infoLocked()
	s.mu.Unlock()
	fn(in)
	return func() {
		s.mu.Lock()
		delete(s.subs, id)
		s.mu.Unlock()
	}
}

func (s *Session) setState(st State, errMsg string) {
	s.mu.Lock()
	if s.state == StateStopped || s.state == StateError {
		s.mu.Unlock()
		return
	}
	s.state = st
	s.errMsg = errMsg
	in := s.infoLocked()
	subs := make([]func(Info), 0, len(s.subs))
	for _, fn := range s.subs {
		subs = append(subs, fn)
	}
	s.mu.Unlock()
	log.Printf("session %s: %s %s", s.ID, st, errMsg)
	for _, fn := range subs {
		fn(in)
	}
}

// start boots the instance. Runs in its own goroutine.
func (s *Session) start(ctx context.Context) {
	ctx, cancel := context.WithTimeout(ctx, s.cfg.StartTimeout)
	defer cancel()

	fail := func(err error) {
		log.Printf("session %s: start failed: %v", s.ID, err)
		s.setState(StateError, err.Error())
		s.teardown()
	}

	d, err := startDisplay(ctx, s.cfg, s.displayNum, s.logDir)
	if err != nil {
		fail(fmt.Errorf("display: %w", err))
		return
	}
	s.mu.Lock()
	s.display = d
	s.mu.Unlock()

	var sink *audioSink
	if s.cfg.Audio {
		sink, err = startAudioSink(s.ID)
		if err != nil {
			log.Printf("session %s: no audio (%v)", s.ID, err)
		}
	}
	s.mu.Lock()
	s.sink = sink
	s.mu.Unlock()

	// In weston mode the game ships its own frames; give it the socket
	// before it boots.
	var bridge *frameBridge
	framePort := 0
	if s.cfg.DisplayMode == config.DisplayWeston {
		bridge, err = newFrameBridge(s.cfg.FPS)
		if err != nil {
			fail(fmt.Errorf("frame bridge: %w", err))
			return
		}
		framePort = bridge.Port()
	}
	s.mu.Lock()
	s.bridge = bridge
	s.mu.Unlock()

	g, err := startGame(s.cfg, d, sink, framePort, s.logDir)
	if err != nil {
		fail(fmt.Errorf("game: %w", err))
		return
	}
	g.onGameFrame = s.gameFrame
	s.mu.Lock()
	s.game = g
	s.mu.Unlock()
	go s.watchGame(g)

	if err := g.waitInput(ctx); err != nil {
		fail(fmt.Errorf("%w\n%s", err, tailLog(s.logDir, "godot", 600)))
		return
	}

	windowID := ""
	if !d.virtual && bridge == nil {
		wctx, wcancel := context.WithTimeout(ctx, 20*time.Second)
		windowID, err = findWindow(wctx, d.name, g.proc.Pid())
		wcancel()
		if err != nil {
			fail(err)
			return
		}
	}
	monitor := ""
	if sink != nil {
		monitor = sink.monitor()
	}
	s.mu.Lock()
	s.cap = &capture{cfg: s.cfg, logDir: s.logDir, display: d.name, windowID: windowID, monitor: monitor, bridge: bridge}
	hasPeer := s.peer != nil
	s.mu.Unlock()

	if hasPeer {
		// A player attached while we were booting: they are already
		// connected (or will be), so start streaming right away.
		s.setState(StateStreaming, "")
		s.startCapture()
	} else {
		s.setState(StateReady, "")
		s.armGrace()
	}
}

// watchGame ends the session when Godot exits on its own (Q key, crash).
func (s *Session) watchGame(g *game) {
	<-g.proc.Done()
	s.mu.Lock()
	closed := s.closed
	s.mu.Unlock()
	if closed {
		return
	}
	_, err := g.proc.Exited()
	msg := "game exited"
	if err != nil {
		msg = fmt.Sprintf("game exited: %v — %s", err, lastLine(tailLog(s.logDir, "godot", 400)))
	}
	s.setState(StateStopped, msg)
	s.teardown()
}

// AttachPeer makes p the player of this session, replacing any previous one.
func (s *Session) AttachPeer(p *rtc.Peer) {
	s.mu.Lock()
	old := s.peer
	s.peer = p
	if s.grace != nil {
		s.grace.Stop()
		s.grace = nil
	}
	s.mu.Unlock()
	if old != nil && old != p {
		old.Close()
	}
}

// PeerConnected is called by the peer once ICE/DTLS are up.
func (s *Session) PeerConnected(p *rtc.Peer) {
	s.mu.Lock()
	if s.peer != p {
		s.mu.Unlock()
		return
	}
	ready := s.cap != nil
	s.lastInput = time.Now()
	s.mu.Unlock()
	if ready {
		s.setState(StateStreaming, "")
		s.startCapture()
	}
	// Tell the game the player is (back): it re-announces the mouse mode.
	if g := s.gameRef(); g != nil {
		_ = g.sendInput([]byte{proto.PingFrame, 0, 0, 0, 0})
	}
}

// PeerDisconnected is called by the peer on close/failure.
func (s *Session) PeerDisconnected(p *rtc.Peer) {
	s.mu.Lock()
	if s.peer != p {
		s.mu.Unlock()
		return
	}
	s.peer = nil
	cap := s.cap
	s.mu.Unlock()
	if cap != nil {
		cap.halt()
	}
	if g := s.gameRef(); g != nil {
		g.releaseAll()
	}
	s.mu.Lock()
	st := s.state
	s.mu.Unlock()
	if st == StateStreaming || st == StateReady {
		s.setState(StateWaiting, "")
	}
	s.armGrace()
}

// armGrace starts the countdown that kills an unattended game.
func (s *Session) armGrace() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.grace != nil {
		s.grace.Stop()
	}
	s.grace = time.AfterFunc(s.cfg.ReconnectGrace, func() {
		s.mu.Lock()
		hasPeer := s.peer != nil
		s.mu.Unlock()
		if !hasPeer {
			s.setState(StateStopped, "no player reconnected in time")
			s.teardown()
		}
	})
}

func (s *Session) startCapture() {
	s.mu.Lock()
	cap, p := s.cap, s.peer
	s.mu.Unlock()
	if cap == nil || p == nil {
		return
	}
	cap.videoRTP = p.VideoAddr()
	cap.audioRTP = p.AudioAddr()
	cap.start()
}

func (s *Session) gameRef() *game {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.game
}

// HandleInput validates a browser frame batch and forwards it to the game.
func (s *Session) HandleInput(b []byte) error {
	if _, err := proto.Split(b, proto.ClientFrame); err != nil {
		return err
	}
	s.mu.Lock()
	s.lastInput = time.Now()
	g := s.game
	booting := s.state == StateStarting
	s.mu.Unlock()
	if booting {
		return nil // player is early; the game is not listening yet
	}
	if g == nil {
		return fmt.Errorf("game not running")
	}
	return g.sendInput(b)
}

// gameFrame relays a frame from the game to the browser.
func (s *Session) gameFrame(b []byte) {
	s.mu.Lock()
	p := s.peer
	s.mu.Unlock()
	if p != nil {
		_ = p.SendToClient(b)
	}
}

// IdleFor is how long the player has been silent.
func (s *Session) IdleFor() time.Duration {
	s.mu.Lock()
	defer s.mu.Unlock()
	return time.Since(s.lastInput)
}

// Close tears the session down now.
func (s *Session) Close(reason string) {
	s.setState(StateStopped, reason)
	s.teardown()
}

func (s *Session) teardown() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	if s.grace != nil {
		s.grace.Stop()
	}
	peer, cap, g, sink, d, bridge := s.peer, s.cap, s.game, s.sink, s.display, s.bridge
	s.peer = nil
	s.mu.Unlock()

	if peer != nil {
		peer.Close()
	}
	if cap != nil {
		cap.halt()
	}
	bridge.stop()
	g.stop()
	sink.stop()
	d.stop()
	if s.onClosed != nil {
		s.onClosed(s)
	}
}
