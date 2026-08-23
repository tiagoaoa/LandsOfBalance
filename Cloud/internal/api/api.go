// Package api is the HTTP surface: static client, session REST and the
// WebSocket signaling channel that carries SDP/ICE for one session.
package api

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"github.com/pion/webrtc/v4"

	"github.com/talves/lands-of-balance/cloud/internal/config"
	"github.com/talves/lands-of-balance/cloud/internal/rtc"
	"github.com/talves/lands-of-balance/cloud/internal/session"
)

// Server holds the dependencies of the handlers.
type Server struct {
	cfg *config.Config
	mgr *session.Manager
	up  websocket.Upgrader
}

// New wires the routes onto a mux.
func New(cfg *config.Config, mgr *session.Manager) http.Handler {
	s := &Server{cfg: cfg, mgr: mgr, up: websocket.Upgrader{
		ReadBufferSize: 4096, WriteBufferSize: 4096,
		CheckOrigin: func(*http.Request) bool { return true }, // token gates what matters
	}}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/health", s.health)
	mux.HandleFunc("GET /api/config", s.config)
	mux.HandleFunc("GET /api/sessions", s.auth(s.listSessions))
	mux.HandleFunc("POST /api/sessions", s.auth(s.createSession))
	mux.HandleFunc("GET /api/sessions/{id}", s.auth(s.getSession))
	mux.HandleFunc("DELETE /api/sessions/{id}", s.auth(s.deleteSession))
	mux.HandleFunc("GET /ws/{id}", s.auth(s.signal))
	mux.Handle("/", http.FileServer(http.Dir(cfg.WebDir)))
	return s.noCache(mux)
}

func (s *Server) noCache(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		h.ServeHTTP(w, r)
	})
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func (s *Server) auth(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if s.cfg.Token != "" {
			tok := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
			if tok == "" {
				tok = r.URL.Query().Get("token")
			}
			if tok != s.cfg.Token {
				writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "bad token"})
				return
			}
		}
		h(w, r)
	}
}

func (s *Server) health(w http.ResponseWriter, _ *http.Request) {
	used, total := s.mgr.Capacity()
	writeJSON(w, 200, map[string]any{"ok": true, "sessions": used, "capacity": total})
}

func (s *Server) config(w http.ResponseWriter, _ *http.Request) {
	used, total := s.mgr.Capacity()
	writeJSON(w, 200, map[string]any{
		"authRequired": s.cfg.Token != "",
		"iceServers":   rtc.ICEServersJSON(s.cfg.ICEServers),
		"width":        s.cfg.Width,
		"height":       s.cfg.Height,
		"fps":          s.cfg.FPS,
		"sessions":     used,
		"capacity":     total,
	})
}

func (s *Server) listSessions(w http.ResponseWriter, _ *http.Request) {
	var out []session.Info
	for _, se := range s.mgr.List() {
		out = append(out, se.Info())
	}
	if out == nil {
		out = []session.Info{}
	}
	writeJSON(w, 200, out)
}

func (s *Server) createSession(w http.ResponseWriter, _ *http.Request) {
	se, err := s.mgr.Create()
	if err != nil {
		code := http.StatusInternalServerError
		if errors.Is(err, session.ErrFull) {
			code = http.StatusServiceUnavailable
		}
		writeJSON(w, code, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"session": se.Info(), "ws": "/ws/" + se.ID})
}

func (s *Server) getSession(w http.ResponseWriter, r *http.Request) {
	se, ok := s.mgr.Get(r.PathValue("id"))
	if !ok {
		writeJSON(w, 404, map[string]string{"error": "no such session"})
		return
	}
	writeJSON(w, 200, se.Info())
}

func (s *Server) deleteSession(w http.ResponseWriter, r *http.Request) {
	se, ok := s.mgr.Get(r.PathValue("id"))
	if !ok {
		writeJSON(w, 404, map[string]string{"error": "no such session"})
		return
	}
	se.Close("deleted by client")
	w.WriteHeader(http.StatusNoContent)
}

// wsMsg is the JSON envelope on the signaling socket.
type wsMsg struct {
	Type      string                   `json:"type"`
	SDP       string                   `json:"sdp,omitempty"`
	Candidate *webrtc.ICECandidateInit `json:"candidate,omitempty"`
	Session   *session.Info            `json:"session,omitempty"`
	Error     string                   `json:"error,omitempty"`
	Stats     *rtc.Stats               `json:"stats,omitempty"`
}

// signal runs the signaling loop for one browser on one session.
func (s *Server) signal(w http.ResponseWriter, r *http.Request) {
	se, ok := s.mgr.Get(r.PathValue("id"))
	if !ok {
		writeJSON(w, 404, map[string]string{"error": "no such session"})
		return
	}
	ws, err := s.up.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	defer ws.Close()

	var wmu sync.Mutex
	send := func(m wsMsg) {
		wmu.Lock()
		defer wmu.Unlock()
		_ = ws.SetWriteDeadline(time.Now().Add(5 * time.Second))
		_ = ws.WriteJSON(m)
	}

	var peer *rtc.Peer
	peer, err = rtc.NewPeer(s.cfg, rtc.Callbacks{
		OnInput:        se.HandleInput,
		OnConnected:    func() { se.PeerConnected(peer) },
		OnDisconnected: func() { se.PeerDisconnected(peer) },
		OnICECandidate: func(c webrtc.ICECandidateInit) { send(wsMsg{Type: "ice", Candidate: &c}) },
	})
	if err != nil {
		send(wsMsg{Type: "error", Error: err.Error()})
		return
	}
	defer peer.Close()
	se.AttachPeer(peer)

	unsub := se.Subscribe(func(in session.Info) {
		send(wsMsg{Type: "state", Session: &in})
	})
	defer unsub()

	// Periodic stats so the client can show server-side counters too.
	stop := make(chan struct{})
	defer close(stop)
	go func() {
		t := time.NewTicker(2 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-stop:
				return
			case <-t.C:
				st := peer.Stats()
				send(wsMsg{Type: "stats", Stats: &st})
			}
		}
	}()

	ws.SetReadLimit(1 << 20)
	for {
		var m wsMsg
		if err := ws.ReadJSON(&m); err != nil {
			return
		}
		switch m.Type {
		case "offer":
			ans, err := peer.Answer(m.SDP)
			if err != nil {
				log.Printf("session %s: %v", se.ID, err)
				send(wsMsg{Type: "error", Error: err.Error()})
				return
			}
			send(wsMsg{Type: "answer", SDP: ans})
		case "ice":
			if m.Candidate != nil {
				if err := peer.AddICECandidate(*m.Candidate); err != nil {
					log.Printf("session %s: ice: %v", se.ID, err)
				}
			}
		case "ping":
			send(wsMsg{Type: "pong"})
		case "leave":
			return
		}
	}
}
