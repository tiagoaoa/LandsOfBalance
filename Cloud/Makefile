GODOT ?= /home/talves/bin/godot
GAME_DIR ?= $(abspath ..)

.PHONY: build run probe game docker test vet

build:            ## build the gateway and the probe into bin/
	go build -o bin/lobcloud ./cmd/lobcloud
	go build -o bin/lobprobe ./cmd/lobprobe

test:
	go vet ./... && go test ./...

run: build        ## stream the game from this desktop (existing display)
	LOB_GODOT=$(GODOT) LOB_GAME_DIR=$(GAME_DIR) bin/lobcloud -display-mode existing $(ARGS)

probe: build      ## headless client: create a session, count packets, round-trip input
	bin/lobprobe -url http://127.0.0.1:8080 $(ARGS)

game:             ## export the game for the container (build/lob_server.x86_64)
	GODOT=$(GODOT) scripts/build_game.sh

docker: game      ## build the container image
	docker build -f docker/Dockerfile -t lobcloud ..
