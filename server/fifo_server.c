/*
 * FIFO-Based Mock Server for Multiplayer Testing
 *
 * Uses named pipes (FIFOs) for IPC between Godot clients and server.
 * Server-authoritative: clients display only server-confirmed state.
 *
 * Compile: gcc -o fifo_server fifo_server.c -lpthread
 * Run: ./fifo_server [max_players]
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/select.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <time.h>

#define MAX_PLAYERS 4
#define FIFO_PATH_PREFIX "/tmp/lob_"
#define BROADCAST_INTERVAL_US 200000  // 200ms = 200000 microseconds

// Player state flags (match Godot protocol.gd)
#define STATE_IDLE      0
#define STATE_WALKING   1
#define STATE_RUNNING   2
#define STATE_ATTACKING 3
#define STATE_BLOCKING  4
#define STATE_JUMPING   5
#define STATE_CASTING   6
#define STATE_DRAWING_BOW 7
#define STATE_HOLDING_BOW 8
#define STATE_DEAD      9

// Message types
#define MSG_PLAYER_UPDATE 1
#define MSG_GLOBAL_STATE  2
#define MSG_JOIN          3
#define MSG_LEAVE         4

#pragma pack(push, 1)

// Player data structure (60 bytes, matches Godot protocol)
typedef struct {
    uint32_t player_id;      // 4 bytes
    float x, y, z;           // 12 bytes - position
    float rotation_y;        // 4 bytes - facing direction
    uint8_t state;           // 1 byte - PlayerState enum
    uint8_t combat_mode;     // 1 byte - 0=unarmed, 1=armed
    float health;            // 4 bytes
    char anim_name[32];      // 32 bytes - current animation
    uint8_t active;          // 1 byte - is player connected
    uint8_t character_class; // 1 byte - 0=paladin, 1=archer
} PlayerData;

// Message header
typedef struct {
    uint8_t msg_type;        // 1 byte
    uint8_t player_count;    // 1 byte
    uint32_t sequence;       // 4 bytes - for ordering
    uint16_t padding;        // 2 bytes - alignment
} MsgHeader;

// Full message structure
typedef struct {
    MsgHeader header;
    PlayerData players[MAX_PLAYERS];
} FifoMessage;

#pragma pack(pop)

// Player connection info
typedef struct {
    int id;
    int to_server_fd;        // Read from player
    int from_server_fd;      // Write to player
    char to_server_path[128];
    char from_server_path[128];
    PlayerData data;
    int connected;
    time_t last_seen;
} PlayerConnection;

// Global state
static PlayerConnection players[MAX_PLAYERS];
static pthread_mutex_t state_mutex = PTHREAD_MUTEX_INITIALIZER;
static volatile int running = 1;
static uint32_t sequence = 0;
static int num_players = 2;

void signal_handler(int sig) {
    printf("\nShutting down FIFO server...\n");
    running = 0;
}

// Get current time in microseconds
uint64_t get_time_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000ULL + ts.tv_nsec / 1000ULL;
}

// Create FIFOs for a player
int create_player_fifos(int player_id) {
    PlayerConnection *p = &players[player_id - 1];
    p->id = player_id;

    snprintf(p->to_server_path, sizeof(p->to_server_path),
             "%splayer%d_to_server", FIFO_PATH_PREFIX, player_id);
    snprintf(p->from_server_path, sizeof(p->from_server_path),
             "%sserver_to_player%d", FIFO_PATH_PREFIX, player_id);

    // Remove existing FIFOs
    unlink(p->to_server_path);
    unlink(p->from_server_path);

    // Create new FIFOs
    if (mkfifo(p->to_server_path, 0666) < 0 && errno != EEXIST) {
        perror("mkfifo to_server");
        return -1;
    }
    if (mkfifo(p->from_server_path, 0666) < 0 && errno != EEXIST) {
        perror("mkfifo from_server");
        return -1;
    }

    printf("Created FIFOs for player %d:\n", player_id);
    printf("  -> %s\n", p->to_server_path);
    printf("  <- %s\n", p->from_server_path);

    // Initialize player data
    p->data.player_id = player_id;
    p->data.x = player_id * 2.0f;  // Spread players apart
    p->data.y = 0.0f;
    p->data.z = 0.0f;
    p->data.rotation_y = 0.0f;
    p->data.state = STATE_IDLE;
    p->data.combat_mode = 1;
    p->data.health = 100.0f;
    strncpy(p->data.anim_name, "Idle", sizeof(p->data.anim_name));
    p->data.active = 0;
    p->data.character_class = 1;  // Archer

    p->connected = 0;
    p->to_server_fd = -1;
    p->from_server_fd = -1;

    return 0;
}

// Open FIFOs for reading/writing
void* connection_handler(void *arg) {
    int player_id = *(int*)arg;
    PlayerConnection *p = &players[player_id - 1];

    printf("Waiting for player %d to connect...\n", player_id);

    // Open BOTH FIFOs with O_RDWR to avoid blocking deadlock
    // This allows the open() to succeed immediately
    p->from_server_fd = open(p->from_server_path, O_RDWR | O_NONBLOCK);
    if (p->from_server_fd < 0) {
        perror("open from_server");
        return NULL;
    }

    p->to_server_fd = open(p->to_server_path, O_RDWR | O_NONBLOCK);
    if (p->to_server_fd < 0) {
        perror("open to_server");
        close(p->from_server_fd);
        p->from_server_fd = -1;
        return NULL;
    }

    pthread_mutex_lock(&state_mutex);
    p->connected = 1;
    p->data.active = 1;
    p->last_seen = time(NULL);
    pthread_mutex_unlock(&state_mutex);

    printf("Player %d connected!\n", player_id);

    return NULL;
}

// Read player updates from FIFO
void read_player_updates(void) {
    FifoMessage msg;

    for (int i = 0; i < num_players; i++) {
        PlayerConnection *p = &players[i];

        if (!p->connected || p->to_server_fd < 0) continue;

        // Non-blocking read
        ssize_t bytes = read(p->to_server_fd, &msg, sizeof(msg));

        if (bytes == sizeof(msg)) {
            if (msg.header.msg_type == MSG_PLAYER_UPDATE) {
                pthread_mutex_lock(&state_mutex);

                // Find the player data in the message
                for (int j = 0; j < msg.header.player_count; j++) {
                    if (msg.players[j].player_id == (uint32_t)(p->id)) {
                        // Update server-side state
                        p->data = msg.players[j];
                        p->data.active = 1;
                        p->last_seen = time(NULL);
                        break;
                    }
                }

                pthread_mutex_unlock(&state_mutex);
            }
        } else if (bytes < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
            // Error or disconnect
            if (errno != EINTR) {
                printf("Player %d read error: %s\n", p->id, strerror(errno));
            }
        }
    }
}

// Broadcast global state to all players
void broadcast_global_state(void) {
    FifoMessage msg;
    memset(&msg, 0, sizeof(msg));

    pthread_mutex_lock(&state_mutex);

    msg.header.msg_type = MSG_GLOBAL_STATE;
    msg.header.sequence = ++sequence;

    // Collect all active player data
    int count = 0;
    for (int i = 0; i < num_players && count < MAX_PLAYERS; i++) {
        if (players[i].connected) {
            msg.players[count] = players[i].data;
            count++;
        }
    }
    msg.header.player_count = count;

    pthread_mutex_unlock(&state_mutex);

    // Write to all connected players
    for (int i = 0; i < num_players; i++) {
        PlayerConnection *p = &players[i];

        if (!p->connected || p->from_server_fd < 0) continue;

        ssize_t bytes = write(p->from_server_fd, &msg, sizeof(msg));
        if (bytes < 0 && errno != EAGAIN && errno != EPIPE) {
            perror("write to player");
        }
    }
}

// Cleanup FIFOs
void cleanup_fifos(void) {
    for (int i = 0; i < num_players; i++) {
        PlayerConnection *p = &players[i];

        if (p->to_server_fd >= 0) close(p->to_server_fd);
        if (p->from_server_fd >= 0) close(p->from_server_fd);

        unlink(p->to_server_path);
        unlink(p->from_server_path);
    }
}

void print_status(void) {
    static int counter = 0;
    if (++counter < 5) return;  // Print every second (5 * 200ms)
    counter = 0;

    pthread_mutex_lock(&state_mutex);

    printf("\n--- Server Status (seq=%u) ---\n", sequence);
    for (int i = 0; i < num_players; i++) {
        PlayerConnection *p = &players[i];
        if (p->connected) {
            printf("Player %d: pos(%.1f, %.1f, %.1f) rot=%.1f state=%d anim=%s\n",
                   p->id, p->data.x, p->data.y, p->data.z,
                   p->data.rotation_y, p->data.state, p->data.anim_name);
        } else {
            printf("Player %d: disconnected\n", p->id);
        }
    }

    pthread_mutex_unlock(&state_mutex);
}

int main(int argc, char *argv[]) {
    if (argc > 1) {
        num_players = atoi(argv[1]);
        if (num_players < 1 || num_players > MAX_PLAYERS) {
            num_players = 2;
        }
    }

    // Setup signal handler
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
    signal(SIGPIPE, SIG_IGN);  // Ignore broken pipe

    printf("===========================================\n");
    printf("  FIFO Mock Server for Multiplayer Testing\n");
    printf("===========================================\n");
    printf("Max players: %d\n", num_players);
    printf("Broadcast interval: %d us (%.1f Hz)\n",
           BROADCAST_INTERVAL_US, 1000000.0 / BROADCAST_INTERVAL_US);
    printf("Press Ctrl+C to stop\n");
    printf("===========================================\n\n");

    // Create FIFOs for all players
    for (int i = 1; i <= num_players; i++) {
        if (create_player_fifos(i) < 0) {
            fprintf(stderr, "Failed to create FIFOs for player %d\n", i);
            cleanup_fifos();
            return 1;
        }
    }

    // Start connection handler threads
    pthread_t conn_threads[MAX_PLAYERS];
    int player_ids[MAX_PLAYERS];
    for (int i = 0; i < num_players; i++) {
        player_ids[i] = i + 1;
        pthread_create(&conn_threads[i], NULL, connection_handler, &player_ids[i]);
    }

    printf("\nWaiting for players to connect...\n");
    printf("Players should open:\n");
    for (int i = 1; i <= num_players; i++) {
        printf("  Player %d: read from %sserver_to_player%d, write to %splayer%d_to_server\n",
               i, FIFO_PATH_PREFIX, i, FIFO_PATH_PREFIX, i);
    }
    printf("\n");

    // Main server loop - 2ms intervals
    uint64_t last_broadcast = get_time_us();

    while (running) {
        // Read updates from all players
        read_player_updates();

        // Check if it's time to broadcast
        uint64_t now = get_time_us();
        if (now - last_broadcast >= BROADCAST_INTERVAL_US) {
            broadcast_global_state();
            last_broadcast = now;
        }

        // Print status periodically
        print_status();

        // Small sleep to avoid busy-waiting
        usleep(100);  // 0.1ms
    }

    // Cleanup
    printf("Cleaning up...\n");
    cleanup_fifos();

    printf("Server stopped.\n");
    return 0;
}
