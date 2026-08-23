// lobprobe is a headless browser stand-in: it creates a session, does the
// signaling dance, counts the media packets that arrive and round-trips an
// input frame through the game. Use it to check a gateway without a browser.
package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
	"github.com/pion/webrtc/v4"
)

type wsMsg struct {
	Type      string                   `json:"type"`
	SDP       string                   `json:"sdp,omitempty"`
	Candidate *webrtc.ICECandidateInit `json:"candidate,omitempty"`
	Session   *json.RawMessage         `json:"session,omitempty"`
	Error     string                   `json:"error,omitempty"`
}

func main() {
	base := flag.String("url", "http://127.0.0.1:8080", "gateway URL")
	token := flag.String("token", os.Getenv("LOB_TOKEN"), "access token")
	dur := flag.Duration("duration", 20*time.Second, "how long to stream before leaving")
	keep := flag.Bool("keep", false, "leave the session running when done")
	flag.Parse()
	log.SetFlags(log.Ltime | log.Lmicroseconds)

	hdr := http.Header{}
	if *token != "" {
		hdr.Set("Authorization", "Bearer "+*token)
	}
	req, _ := http.NewRequest("POST", *base+"/api/sessions", nil)
	req.Header = hdr
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		log.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 201 {
		log.Fatalf("create session: %s %s", resp.Status, body)
	}
	var created struct {
		Session struct{ ID string } `json:"session"`
		WS      string              `json:"ws"`
	}
	_ = json.Unmarshal(body, &created)
	id := created.Session.ID
	log.Printf("session %s", id)

	u, _ := url.Parse(*base)
	u.Scheme = map[string]string{"http": "ws", "https": "wss"}[u.Scheme]
	u.Path = created.WS
	ws, _, err := websocket.DefaultDialer.Dial(u.String(), hdr)
	if err != nil {
		log.Fatal(err)
	}
	defer ws.Close()

	pc, err := webrtc.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		log.Fatal(err)
	}
	defer pc.Close()
	var videoPkts, audioPkts, videoBytes int64
	pc.OnTrack(func(tr *webrtc.TrackRemote, _ *webrtc.RTPReceiver) {
		log.Printf("track %s %s", tr.Kind(), tr.Codec().MimeType)
		go func() {
			for {
				p, _, err := tr.ReadRTP()
				if err != nil {
					return
				}
				if tr.Kind() == webrtc.RTPCodecTypeVideo {
					atomic.AddInt64(&videoPkts, 1)
					atomic.AddInt64(&videoBytes, int64(len(p.Payload)))
				} else {
					atomic.AddInt64(&audioPkts, 1)
				}
			}
		}()
	})
	if _, err := pc.AddTransceiverFromKind(webrtc.RTPCodecTypeVideo, webrtc.RTPTransceiverInit{Direction: webrtc.RTPTransceiverDirectionRecvonly}); err != nil {
		log.Fatal(err)
	}
	if _, err := pc.AddTransceiverFromKind(webrtc.RTPCodecTypeAudio, webrtc.RTPTransceiverInit{Direction: webrtc.RTPTransceiverDirectionRecvonly}); err != nil {
		log.Fatal(err)
	}
	input, err := pc.CreateDataChannel("input", nil)
	if err != nil {
		log.Fatal(err)
	}
	gotHello := make(chan struct{}, 1)
	gotPong := make(chan uint32, 4)
	gotMouse := make(chan byte, 4)
	input.OnMessage(func(m webrtc.DataChannelMessage) {
		d := m.Data
		for len(d) > 0 {
			switch d[0] {
			case 0x82:
				select {
				case gotHello <- struct{}{}:
				default:
				}
				d = d[2:]
			case 0x81:
				gotPong <- binary.LittleEndian.Uint32(d[1:5])
				d = d[5:]
			case 0x80:
				select {
				case gotMouse <- d[1]:
				default:
				}
				d = d[2:]
			default:
				log.Printf("unknown game frame 0x%02x", d[0])
				return
			}
		}
	})
	var pongSeen atomic.Bool
	input.OnOpen(func() {
		log.Printf("input channel open")
		// Every 2s until answered: PING, then tap and release the A key
		// (keycode 65) — the game may still be booting when we open.
		go func() {
			for seq := uint32(1); !pongSeen.Load() && input.ReadyState() == webrtc.DataChannelStateOpen; seq++ {
				var buf bytes.Buffer
				ping := []byte{0x08, 0, 0, 0, 0}
				binary.LittleEndian.PutUint32(ping[1:], seq)
				buf.Write(ping)
				key := func(pressed byte) {
					f := make([]byte, 17)
					f[0] = 0x01
					f[1] = pressed
					binary.LittleEndian.PutUint32(f[2:], 65)
					binary.LittleEndian.PutUint32(f[6:], 65)
					buf.Write(f)
				}
				key(1)
				key(0)
				_ = input.Send(buf.Bytes())
				time.Sleep(2 * time.Second)
			}
		}()
	})
	pc.OnICECandidate(func(c *webrtc.ICECandidate) {
		if c != nil {
			ci := c.ToJSON()
			_ = ws.WriteJSON(wsMsg{Type: "ice", Candidate: &ci})
		}
	})
	pc.OnConnectionStateChange(func(s webrtc.PeerConnectionState) { log.Printf("peer %s", s) })

	offer, err := pc.CreateOffer(nil)
	if err != nil {
		log.Fatal(err)
	}
	if err := pc.SetLocalDescription(offer); err != nil {
		log.Fatal(err)
	}
	_ = ws.WriteJSON(wsMsg{Type: "offer", SDP: offer.SDP})

	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			var m wsMsg
			if err := ws.ReadJSON(&m); err != nil {
				return
			}
			switch m.Type {
			case "answer":
				if err := pc.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeAnswer, SDP: m.SDP}); err != nil {
					log.Fatal(err)
				}
			case "ice":
				if m.Candidate != nil {
					_ = pc.AddICECandidate(*m.Candidate)
				}
			case "state":
				s := strings.TrimSpace(string(*m.Session))
				log.Printf("state %s", s)
			case "error":
				log.Fatalf("gateway error: %s", m.Error)
			}
		}
	}()

	deadline := time.After(*dur)
	tick := time.NewTicker(2 * time.Second)
	helloOK, pongOK, mouseOK := false, false, false
	last := int64(0)
loop:
	for {
		select {
		case <-gotHello:
			if !helloOK {
				log.Printf("game said HELLO")
			}
			helloOK = true
		case seq := <-gotPong:
			pongSeen.Store(true)
			if !pongOK {
				log.Printf("game answered PING (seq %d)", seq)
			}
			pongOK = true
		case m := <-gotMouse:
			if !mouseOK {
				log.Printf("game mouse mode = %d", m)
			}
			mouseOK = true
		case <-tick.C:
			v := atomic.LoadInt64(&videoPkts)
			b := atomic.LoadInt64(&videoBytes)
			log.Printf("video %d pkts (%d kbit/s) audio %d pkts", v, (b-last)*8/2000, atomic.LoadInt64(&audioPkts))
			last = b
		case <-deadline:
			break loop
		case <-done:
			log.Printf("signaling closed")
			break loop
		}
	}
	v, a := atomic.LoadInt64(&videoPkts), atomic.LoadInt64(&audioPkts)
	fmt.Printf("RESULT video_packets=%d audio_packets=%d hello=%v pong=%v mouse_mode=%v\n", v, a, helloOK, pongOK, mouseOK)
	if !*keep {
		req, _ := http.NewRequest("DELETE", *base+"/api/sessions/"+id, nil)
		req.Header = hdr
		if r, err := http.DefaultClient.Do(req); err == nil {
			r.Body.Close()
		}
	}
	if v == 0 || !pongOK {
		os.Exit(1)
	}
}
