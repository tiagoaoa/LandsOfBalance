package proto

import "testing"

func TestSplit(t *testing.T) {
	key := make([]byte, 17)
	key[0] = KeyFrame
	joy := append([]byte{JoyConnectFrame, 0, 1, 3}, 'p', 'a', 'd')
	buf := append(append([]byte{}, key...), joy...)
	buf = append(buf, ReleaseAllFrame)
	n, err := Split(buf, ClientFrame)
	if err != nil || n != 3 {
		t.Fatalf("got %d, %v", n, err)
	}
	if _, err := Split(buf[:10], ClientFrame); err == nil {
		t.Fatal("short frame accepted")
	}
	if _, err := Split([]byte{0x42}, ClientFrame); err == nil {
		t.Fatal("unknown type accepted")
	}
	if _, err := Split([]byte{MouseModeFrame, 2}, ClientFrame); err == nil {
		t.Fatal("game frame accepted from client")
	}
}
