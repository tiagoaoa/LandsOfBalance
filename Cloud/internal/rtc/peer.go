// Package rtc wraps a Pion peer connection for one player: two outgoing
// tracks fed by RTP that ffmpeg sends to loopback UDP ports, and the data
// channels that carry input both ways.
package rtc

import (
	"fmt"
	"log"
	"net"
	"strings"
	"sync"
	"time"

	"github.com/pion/ice/v4"
	"github.com/pion/interceptor"
	"github.com/pion/webrtc/v4"

	"github.com/talves/lands-of-balance/cloud/internal/config"
)

const (
	h264Fmtp = "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f"
	opusFmtp = "minptime=10;useinbandfec=1"
)

var (
	tcpMuxOnce sync.Once
	tcpMux     ice.TCPMux
	tcpMuxErr  error
)

// tcpMuxFor lazily opens the single shared ICE-TCP listener.
func tcpMuxFor(port int) (ice.TCPMux, error) {
	tcpMuxOnce.Do(func() {
		ln, err := net.Listen("tcp4", fmt.Sprintf(":%d", port))
		if err != nil {
			tcpMuxErr = err
			return
		}
		log.Printf("ICE-TCP listening on %s", ln.Addr())
		tcpMux = webrtc.NewICETCPMux(nil, ln, 8)
	})
	return tcpMux, tcpMuxErr
}

// Callbacks are the hooks the session plugs into a peer.
type Callbacks struct {
	OnInput        func([]byte) error
	OnConnected    func()
	OnDisconnected func()
	OnICECandidate func(webrtc.ICECandidateInit)
}

// Peer is one browser's connection.
type Peer struct {
	pc    *webrtc.PeerConnection
	cb    Callbacks
	video *webrtc.TrackLocalStaticRTP
	audio *webrtc.TrackLocalStaticRTP
	vconn *net.UDPConn
	aconn *net.UDPConn

	mu        sync.Mutex
	inputDC   *webrtc.DataChannel
	closed    bool
	connected bool
	stats     Stats
}

// Stats are cheap counters for the status endpoint.
type Stats struct {
	VideoPackets uint64 `json:"videoPackets"`
	VideoBytes   uint64 `json:"videoBytes"`
	AudioPackets uint64 `json:"audioPackets"`
	InputFrames  uint64 `json:"inputMessages"`
}

func parseICEServers(list []string) []webrtc.ICEServer {
	var out []webrtc.ICEServer
	for _, s := range list {
		// turn:user:pass@host:port?transport=tcp → URLs + credentials
		if strings.HasPrefix(s, "turn:") || strings.HasPrefix(s, "turns:") {
			scheme, rest, _ := strings.Cut(s, ":")
			if cred, host, ok := strings.Cut(rest, "@"); ok {
				user, pass, _ := strings.Cut(cred, ":")
				out = append(out, webrtc.ICEServer{URLs: []string{scheme + ":" + host}, Username: user, Credential: pass})
				continue
			}
		}
		out = append(out, webrtc.ICEServer{URLs: []string{s}})
	}
	return out
}

// ICEServersJSON is the client-side view of the ICE config.
func ICEServersJSON(list []string) []map[string]any {
	var out []map[string]any
	for _, s := range parseICEServers(list) {
		m := map[string]any{"urls": s.URLs}
		if s.Username != "" {
			m["username"] = s.Username
			m["credential"] = s.Credential
		}
		out = append(out, m)
	}
	return out
}

// NewPeer builds the peer connection and binds the RTP ingest sockets.
func NewPeer(cfg *config.Config, cb Callbacks) (*Peer, error) {
	me := &webrtc.MediaEngine{}
	if err := me.RegisterCodec(webrtc.RTPCodecParameters{
		RTPCodecCapability: webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeH264, ClockRate: 90000, SDPFmtpLine: h264Fmtp,
			RTCPFeedback: []webrtc.RTCPFeedback{{Type: "goog-remb"}, {Type: "ccm", Parameter: "fir"}, {Type: "nack"}, {Type: "nack", Parameter: "pli"}}},
		PayloadType: 102,
	}, webrtc.RTPCodecTypeVideo); err != nil {
		return nil, err
	}
	if err := me.RegisterCodec(webrtc.RTPCodecParameters{
		RTPCodecCapability: webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeOpus, ClockRate: 48000, Channels: 2, SDPFmtpLine: opusFmtp},
		PayloadType: 111,
	}, webrtc.RTPCodecTypeAudio); err != nil {
		return nil, err
	}
	ir := &interceptor.Registry{}
	if err := webrtc.RegisterDefaultInterceptors(me, ir); err != nil {
		return nil, err
	}
	se := webrtc.SettingEngine{}
	if cfg.PublicIP != "" {
		se.SetNAT1To1IPs([]string{cfg.PublicIP}, webrtc.ICECandidateTypeHost)
	}
	if cfg.UDPPortMin > 0 {
		if err := se.SetEphemeralUDPPortRange(uint16(cfg.UDPPortMin), uint16(cfg.UDPPortMax)); err != nil {
			return nil, err
		}
	}
	if cfg.ICETCPPort > 0 {
		// One shared passive-TCP mux for every peer: browsers fall back to
		// ICE-TCP where the host's UDP is unreachable (vast.ai without UDP
		// mappings, corporate NAT). Worse for latency than UDP, but a
		// stream that arrives beats a stream that does not.
		mux, err := tcpMuxFor(cfg.ICETCPPort)
		if err != nil {
			return nil, err
		}
		se.SetICETCPMux(mux)
		se.SetNetworkTypes([]webrtc.NetworkType{
			webrtc.NetworkTypeUDP4, webrtc.NetworkTypeUDP6, webrtc.NetworkTypeTCP4})
	}
	se.SetICETimeouts(8*time.Second, 20*time.Second, 2*time.Second)
	api := webrtc.NewAPI(webrtc.WithMediaEngine(me), webrtc.WithInterceptorRegistry(ir), webrtc.WithSettingEngine(se))

	pc, err := api.NewPeerConnection(webrtc.Configuration{ICEServers: parseICEServers(cfg.ICEServers)})
	if err != nil {
		return nil, err
	}
	p := &Peer{pc: pc, cb: cb}

	// Distinct stream ids on purpose: tracks that share an msid get
	// lip-synced by the browser, which means video waits for the audio
	// jitter buffer. For a game we want each track played the moment it
	// arrives; the client still puts both in one MediaStream for playback.
	p.video, err = webrtc.NewTrackLocalStaticRTP(webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeH264, ClockRate: 90000, SDPFmtpLine: h264Fmtp}, "video", "lob-video")
	if err != nil {
		pc.Close()
		return nil, err
	}
	p.audio, err = webrtc.NewTrackLocalStaticRTP(webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeOpus, ClockRate: 48000, Channels: 2, SDPFmtpLine: opusFmtp}, "audio", "lob-audio")
	if err != nil {
		pc.Close()
		return nil, err
	}
	for _, t := range []*webrtc.TrackLocalStaticRTP{p.video, p.audio} {
		sender, err := pc.AddTrack(t)
		if err != nil {
			pc.Close()
			return nil, err
		}
		// Drain RTCP so the interceptors (NACK, reports) keep working.
		go func() {
			buf := make([]byte, 1500)
			for {
				if _, _, err := sender.Read(buf); err != nil {
					return
				}
			}
		}()
	}

	p.vconn, err = net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		pc.Close()
		return nil, err
	}
	p.aconn, err = net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		p.vconn.Close()
		pc.Close()
		return nil, err
	}
	// A scene load can hitch the game for a second; ffmpeg, being real-time,
	// then bursts the backlog at once. Without headroom the kernel drops the
	// overflow and the browser loses whole frames. 4 MB covers ~4 s at 8 Mbit/s.
	_ = p.vconn.SetReadBuffer(4 << 20)
	_ = p.aconn.SetReadBuffer(1 << 20)
	go p.forward(p.vconn, p.video, &p.stats.VideoPackets, &p.stats.VideoBytes)
	go p.forward(p.aconn, p.audio, &p.stats.AudioPackets, nil)

	pc.OnICECandidate(func(c *webrtc.ICECandidate) {
		if c != nil && cb.OnICECandidate != nil {
			cb.OnICECandidate(c.ToJSON())
		}
	})
	pc.OnConnectionStateChange(func(st webrtc.PeerConnectionState) {
		log.Printf("peer: %s", st)
		switch st {
		case webrtc.PeerConnectionStateConnected:
			p.mu.Lock()
			first := !p.connected
			p.connected = true
			p.mu.Unlock()
			if first && cb.OnConnected != nil {
				cb.OnConnected()
			}
		case webrtc.PeerConnectionStateFailed, webrtc.PeerConnectionStateClosed, webrtc.PeerConnectionStateDisconnected:
			p.Close()
		}
	})
	pc.OnDataChannel(func(dc *webrtc.DataChannel) {
		label := dc.Label()
		if label == "input" {
			p.mu.Lock()
			p.inputDC = dc
			p.mu.Unlock()
		}
		dc.OnMessage(func(msg webrtc.DataChannelMessage) {
			if msg.IsString || cb.OnInput == nil {
				return
			}
			p.mu.Lock()
			p.stats.InputFrames++
			p.mu.Unlock()
			if err := cb.OnInput(msg.Data); err != nil {
				log.Printf("peer: input on %q rejected: %v", label, err)
			}
		})
	})
	return p, nil
}

// forward copies RTP packets from a loopback socket into a track.
func (p *Peer) forward(conn *net.UDPConn, track *webrtc.TrackLocalStaticRTP, pkts, bytes *uint64) {
	buf := make([]byte, 2048)
	for {
		n, _, err := conn.ReadFromUDP(buf)
		if err != nil {
			return
		}
		if _, err := track.Write(buf[:n]); err != nil {
			// Not bound yet (before the answer) or closed: drop silently.
			continue
		}
		p.mu.Lock()
		*pkts++
		if bytes != nil {
			*bytes += uint64(n)
		}
		p.mu.Unlock()
	}
}

// VideoAddr is where ffmpeg should send the H.264 RTP stream.
func (p *Peer) VideoAddr() string { return p.vconn.LocalAddr().String() }

// AudioAddr is where ffmpeg should send the Opus RTP stream.
func (p *Peer) AudioAddr() string { return p.aconn.LocalAddr().String() }

// Answer applies the browser's offer and returns our answer once ICE
// gathering of host candidates is under way (trickle handles the rest).
func (p *Peer) Answer(offerSDP string) (string, error) {
	if err := p.pc.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeOffer, SDP: offerSDP}); err != nil {
		return "", fmt.Errorf("set remote: %w", err)
	}
	ans, err := p.pc.CreateAnswer(nil)
	if err != nil {
		return "", fmt.Errorf("create answer: %w", err)
	}
	if err := p.pc.SetLocalDescription(ans); err != nil {
		return "", fmt.Errorf("set local: %w", err)
	}
	return p.pc.LocalDescription().SDP, nil
}

// AddICECandidate feeds a trickled candidate from the browser.
func (p *Peer) AddICECandidate(c webrtc.ICECandidateInit) error {
	return p.pc.AddICECandidate(c)
}

// SendToClient pushes a game→browser frame over the input channel.
func (p *Peer) SendToClient(b []byte) error {
	p.mu.Lock()
	dc := p.inputDC
	p.mu.Unlock()
	if dc == nil || dc.ReadyState() != webrtc.DataChannelStateOpen {
		return fmt.Errorf("input channel not open")
	}
	return dc.Send(b)
}

// Stats returns the counters.
func (p *Peer) Stats() Stats {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.stats
}

// Close shuts the connection and the ingest sockets; idempotent.
func (p *Peer) Close() {
	p.mu.Lock()
	if p.closed {
		p.mu.Unlock()
		return
	}
	p.closed = true
	p.mu.Unlock()
	p.vconn.Close()
	p.aconn.Close()
	_ = p.pc.Close()
	if p.cb.OnDisconnected != nil {
		p.cb.OnDisconnected()
	}
}
