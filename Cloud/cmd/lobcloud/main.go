// lobcloud is the Lands of Balance cloud gaming gateway: it runs the game on
// this machine and streams it to browsers over WebRTC.
package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/talves/lands-of-balance/cloud/internal/api"
	"github.com/talves/lands-of-balance/cloud/internal/config"
	"github.com/talves/lands-of-balance/cloud/internal/session"
)

func main() {
	cfg, err := config.Parse(os.Args[1:])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	log.SetFlags(log.Ltime | log.Lmicroseconds)

	mgr, err := session.NewManager(cfg)
	if err != nil {
		log.Fatal(err)
	}
	srv := &http.Server{Addr: cfg.Listen, Handler: api.New(cfg, mgr)}

	go func() {
		log.Printf("lobcloud listening on %s (display-mode=%s, %dx%d@%d, encoder=%s, max-sessions=%d, game=%s %s)",
			cfg.Listen, cfg.DisplayMode, cfg.Width, cfg.Height, cfg.FPS, cfg.Encoder, cfg.MaxSessions, cfg.GodotBin, cfg.GameDir)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatal(err)
		}
	}()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
	log.Printf("shutting down")
	mgr.Shutdown()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = srv.Shutdown(ctx)
}
