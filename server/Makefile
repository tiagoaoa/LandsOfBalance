# Douglass The Keeper - Game Server Makefile

CC = gcc
CFLAGS = -Wall -Wextra -O2
LDFLAGS = -lpthread -lm

TARGET = game_server
FIFO_TARGET = fifo_server
FIFO_CLIENT = fifo_test_client
FIFO_AUTO = fifo_auto_test
BOT_CLIENT = bot_client
SRC = game_server.c
FIFO_SRC = fifo_server.c
FIFO_CLIENT_SRC = fifo_test_client.c
FIFO_AUTO_SRC = fifo_auto_test.c
BOT_SRC = bot_client.c

.PHONY: all clean install fifo run run-fifo test bot

all: $(TARGET) $(FIFO_TARGET) $(FIFO_CLIENT) $(BOT_CLIENT)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

$(FIFO_TARGET): $(FIFO_SRC)
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

$(FIFO_CLIENT): $(FIFO_CLIENT_SRC)
	$(CC) $(CFLAGS) -o $@ $< -lm

$(FIFO_AUTO): $(FIFO_AUTO_SRC)
	$(CC) $(CFLAGS) -o $@ $< -lm

$(BOT_CLIENT): $(BOT_SRC)
	$(CC) $(CFLAGS) -o $@ $< -lm

fifo: $(FIFO_TARGET) $(FIFO_CLIENT) $(FIFO_AUTO)

bot: $(BOT_CLIENT)

test: fifo
	@echo "Starting FIFO server..."
	./$(FIFO_TARGET) 1 &
	@sleep 1
	@echo "Starting test client..."
	./$(FIFO_CLIENT) 1

autotest: fifo
	@echo "=== Headless Auto Test ==="
	@rm -f /tmp/lob_*
	./$(FIFO_TARGET) 1 & SERVER_PID=$$!; sleep 1; ./$(FIFO_AUTO) 1; kill $$SERVER_PID 2>/dev/null; rm -f /tmp/lob_*

clean:
	rm -f $(TARGET) $(FIFO_TARGET) $(FIFO_CLIENT) $(FIFO_AUTO) $(BOT_CLIENT)

install: $(TARGET)
	cp $(TARGET) /usr/local/bin/

# Run UDP server with default port
run: $(TARGET)
	./$(TARGET)

# Run FIFO server for local multiplayer testing
run-fifo: $(FIFO_TARGET)
	./$(FIFO_TARGET) $(PLAYERS)

# Run with custom port
run-port: $(TARGET)
	./$(TARGET) $(PORT)
