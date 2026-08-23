// Package proto defines the binary input protocol spoken between the browser,
// the gateway and the game.
//
// The browser encodes events into fixed-size frames, the gateway only checks
// them for shape and forwards them over TCP to the CloudInput autoload in
// Godot, which turns them into InputEvents. Keeping the gateway dumb means
// one definition (here and in autoload/cloud_input.gd) instead of three.
//
// All integers are little-endian. Frame layout (first byte is the type):
//
//	0x01 KEY          pressed u8, keycode u32, physical u32, unicode u32, mods u8, echo u8, location u8   (17)
//	0x02 MOUSE_MOVE   x f32, y f32, dx f32, dy f32, buttons u8                                            (18)
//	0x03 MOUSE_BUTTON pressed u8, button u8, x f32, y f32, factor f32, mods u8, double u8               (17)
//	0x04 JOY_BUTTON   device u8, button u8, pressed u8, pressure f32                                      (8)
//	0x05 JOY_AXIS     device u8, axis u8, value f32                                                       (7)
//	0x06 JOY_CONNECT  device u8, connected u8, name_len u8, name[name_len]                                (4+n)
//	0x07 RELEASE_ALL                                                                                       (1)
//	0x08 PING         seq u32                                                                              (5)
//
// Game → gateway → browser:
//
//	0x80 MOUSE_MODE   mode u8 (Godot Input.MouseMode)                                                     (2)
//	0x81 PONG         seq u32                                                                              (5)
//	0x82 HELLO        version u8                                                                           (2)
package proto

import "fmt"

const (
	KeyFrame         = 0x01
	MouseMoveFrame   = 0x02
	MouseButtonFrame = 0x03
	JoyButtonFrame   = 0x04
	JoyAxisFrame     = 0x05
	JoyConnectFrame  = 0x06
	ReleaseAllFrame  = 0x07
	PingFrame        = 0x08

	MouseModeFrame = 0x80
	PongFrame      = 0x81
	HelloFrame     = 0x82
)

// fixedLen maps a frame type to its total length, or 0 for variable length.
var fixedLen = map[byte]int{
	KeyFrame:         17,
	MouseMoveFrame:   18,
	MouseButtonFrame: 17,
	JoyButtonFrame:   8,
	JoyAxisFrame:     7,
	ReleaseAllFrame:  1,
	PingFrame:        5,
	MouseModeFrame:   2,
	PongFrame:        5,
	HelloFrame:       2,
}

// FrameLen returns the length of the frame that starts at buf[0], or 0 if
// more bytes are needed, or an error if the type is unknown.
func FrameLen(buf []byte) (int, error) {
	if len(buf) == 0 {
		return 0, nil
	}
	t := buf[0]
	if n, ok := fixedLen[t]; ok {
		return n, nil
	}
	if t == JoyConnectFrame {
		if len(buf) < 4 {
			return 0, nil
		}
		return 4 + int(buf[3]), nil
	}
	return 0, fmt.Errorf("unknown frame type 0x%02x", t)
}

// Split validates a buffer holding zero or more whole frames and returns the
// number of frames. It rejects partial frames: the browser always sends whole
// frames per message, so a short buffer means corruption, not fragmentation.
func Split(buf []byte, allowed func(byte) bool) (int, error) {
	n := 0
	for len(buf) > 0 {
		l, err := FrameLen(buf)
		if err != nil {
			return n, err
		}
		if l == 0 || l > len(buf) {
			return n, fmt.Errorf("short frame type 0x%02x: have %d bytes", buf[0], len(buf))
		}
		if !allowed(buf[0]) {
			return n, fmt.Errorf("frame type 0x%02x not allowed here", buf[0])
		}
		buf = buf[l:]
		n++
	}
	return n, nil
}

// ClientFrame reports whether the type may be sent by the browser.
func ClientFrame(t byte) bool { return t >= KeyFrame && t <= PingFrame }

// GameFrame reports whether the type may be sent by the game.
func GameFrame(t byte) bool { return t >= MouseModeFrame && t <= HelloFrame }
