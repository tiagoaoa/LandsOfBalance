package session

import (
	"fmt"
	"log"
	"os/exec"
	"strings"
)

// audioSink is a PulseAudio null sink the game plays into and ffmpeg
// records from (<sink>.monitor). Works with real PulseAudio and with
// pipewire-pulse alike.
type audioSink struct {
	name   string
	module string
}

func startAudioSink(id string) (*audioSink, error) {
	name := "lob_" + id
	out, err := exec.Command("pactl", "load-module", "module-null-sink",
		"sink_name="+name, "rate=48000", "channels=2",
		"sink_properties=device.description="+name).Output()
	if err != nil {
		return nil, fmt.Errorf("pactl load-module: %w", err)
	}
	return &audioSink{name: name, module: strings.TrimSpace(string(out))}, nil
}

func (a *audioSink) monitor() string { return a.name + ".monitor" }

func (a *audioSink) stop() {
	if a == nil || a.module == "" {
		return
	}
	if err := exec.Command("pactl", "unload-module", a.module).Run(); err != nil {
		log.Printf("pactl unload-module %s: %v", a.module, err)
	}
}
