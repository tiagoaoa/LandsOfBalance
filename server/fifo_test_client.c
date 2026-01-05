/*
 * FIFO Test Client - Grid-based movement with acknowledgement
 *
 * Tests server-authoritative movement on a 1m² grid.
 * Player sends position change, waits for server acknowledgement.
 *
 * Compile: gcc -o fifo_test_client fifo_test_client.c -lm
 * Run: ./fifo_test_client <player_id>
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <time.h>
#include <math.h>

#define FIFO_PATH_PREFIX "/tmp/lob_"
#define MAX_PLAYERS 4
#define ACK_TIMEOUT_MS 1000  // 1 second timeout for acknowledgement

// Message types
#define MSG_PLAYER_UPDATE 1
#define MSG_GLOBAL_STATE  2

#pragma pack(push, 1)

typedef struct {
    uint32_t player_id;
    float x, y, z;
    float rotation_y;
    uint8_t state;
    uint8_t combat_mode;
    float health;
    char anim_name[32];
    uint8_t active;
    uint8_t character_class;
} PlayerData;

typedef struct {
    uint8_t msg_type;
    uint8_t player_count;
    uint32_t sequence;
    uint16_t padding;
} MsgHeader;

typedef struct {
    MsgHeader header;
    PlayerData players[MAX_PLAYERS];
} FifoMessage;

#pragma pack(pop)

static volatile int running = 1;
static int player_id = 1;

// Current position (grid-based, integers)
static int grid_x = 0;
static int grid_z = 0;

// Pending move (waiting for ack)
static int pending_x = 0;
static int pending_z = 0;
static int has_pending_move = 0;
static uint32_t pending_seq = 0;

// Server-confirmed position
static int confirmed_x = 0;
static int confirmed_z = 0;

// Statistics
static int moves_sent = 0;
static int moves_acked = 0;
static int moves_failed = 0;

void signal_handler(int sig) {
    (void)sig;
    running = 0;
}

uint64_t get_time_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000ULL + ts.tv_nsec / 1000000ULL;
}

void print_grid(void) {
    printf("\n");
    printf("=== Player %d Grid Position ===\n", player_id);
    printf("Current grid:    (%d, %d)\n", grid_x, grid_z);
    printf("Confirmed:       (%d, %d)\n", confirmed_x, confirmed_z);
    if (has_pending_move) {
        printf("Pending move to: (%d, %d) [seq=%u]\n", pending_x, pending_z, pending_seq);
    }
    printf("Stats: sent=%d acked=%d failed=%d\n", moves_sent, moves_acked, moves_failed);
    printf("===============================\n");
}

int send_position(int to_server_fd, int new_x, int new_z, uint32_t seq) {
    FifoMessage msg;
    memset(&msg, 0, sizeof(msg));

    msg.header.msg_type = MSG_PLAYER_UPDATE;
    msg.header.player_count = 1;
    msg.header.sequence = seq;

    msg.players[0].player_id = player_id;
    msg.players[0].x = (float)new_x;
    msg.players[0].y = 0.0f;
    msg.players[0].z = (float)new_z;
    msg.players[0].rotation_y = 0.0f;
    msg.players[0].state = 1;  // Walking
    msg.players[0].combat_mode = 1;
    msg.players[0].health = 100.0f;
    strncpy(msg.players[0].anim_name, "Walk", 32);
    msg.players[0].active = 1;
    msg.players[0].character_class = 1;

    ssize_t written = write(to_server_fd, &msg, sizeof(msg));
    if (written != sizeof(msg)) {
        fprintf(stderr, "[ERROR] Failed to send position update: %s\n", strerror(errno));
        return -1;
    }

    printf("[SEND] Move request: (%d, %d) -> (%d, %d) seq=%u\n",
           grid_x, grid_z, new_x, new_z, seq);
    return 0;
}

int check_acknowledgement(int from_server_fd, uint32_t expected_seq) {
    FifoMessage msg;

    // Non-blocking read
    ssize_t bytes = read(from_server_fd, &msg, sizeof(msg));

    if (bytes == sizeof(msg) && msg.header.msg_type == MSG_GLOBAL_STATE) {
        // Find our player in the response
        for (int i = 0; i < msg.header.player_count; i++) {
            if (msg.players[i].player_id == (uint32_t)player_id) {
                int server_x = (int)roundf(msg.players[i].x);
                int server_z = (int)roundf(msg.players[i].z);

                printf("[RECV] Server state seq=%u: position=(%d, %d)\n",
                       msg.header.sequence, server_x, server_z);

                // Check if server confirmed our pending position
                if (has_pending_move) {
                    if (server_x == pending_x && server_z == pending_z) {
                        printf("[ACK]  Move CONFIRMED: (%d, %d)\n", server_x, server_z);
                        confirmed_x = server_x;
                        confirmed_z = server_z;
                        grid_x = server_x;
                        grid_z = server_z;
                        has_pending_move = 0;
                        moves_acked++;
                        return 1;  // Acknowledged
                    }
                }

                // Update confirmed position from server
                confirmed_x = server_x;
                confirmed_z = server_z;
                return 0;
            }
        }
    }

    return 0;  // No ack yet
}

void move_player(int to_server_fd, int dx, int dz, uint32_t *seq) {
    if (has_pending_move) {
        printf("[WARN] Cannot move: pending move not yet acknowledged\n");
        return;
    }

    int new_x = grid_x + dx;
    int new_z = grid_z + dz;

    (*seq)++;
    if (send_position(to_server_fd, new_x, new_z, *seq) == 0) {
        pending_x = new_x;
        pending_z = new_z;
        pending_seq = *seq;
        has_pending_move = 1;
        moves_sent++;
    }
}

int main(int argc, char *argv[]) {
    if (argc > 1) {
        player_id = atoi(argv[1]);
    }

    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    printf("===========================================\n");
    printf("  FIFO Test Client - Grid Movement\n");
    printf("===========================================\n");
    printf("Player ID: %d\n", player_id);
    printf("Grid cell size: 1m x 1m\n");
    printf("Commands: w/a/s/d = move, p = print, q = quit\n");
    printf("===========================================\n\n");

    // Build FIFO paths
    char to_server_path[128], from_server_path[128];
    snprintf(to_server_path, sizeof(to_server_path),
             "%splayer%d_to_server", FIFO_PATH_PREFIX, player_id);
    snprintf(from_server_path, sizeof(from_server_path),
             "%sserver_to_player%d", FIFO_PATH_PREFIX, player_id);

    printf("Connecting to FIFOs...\n");
    printf("  Write: %s\n", to_server_path);
    printf("  Read:  %s\n", from_server_path);

    // Open write FIFO first
    int to_server_fd = open(to_server_path, O_WRONLY);
    if (to_server_fd < 0) {
        fprintf(stderr, "Failed to open %s: %s\n", to_server_path, strerror(errno));
        fprintf(stderr, "Is fifo_server running?\n");
        return 1;
    }

    // Open read FIFO (non-blocking)
    int from_server_fd = open(from_server_path, O_RDONLY | O_NONBLOCK);
    if (from_server_fd < 0) {
        fprintf(stderr, "Failed to open %s: %s\n", from_server_path, strerror(errno));
        close(to_server_fd);
        return 1;
    }

    printf("Connected!\n\n");

    // Send initial position
    uint32_t seq = 0;
    send_position(to_server_fd, grid_x, grid_z, ++seq);

    // Set stdin to non-blocking
    int flags = fcntl(STDIN_FILENO, F_GETFL, 0);
    fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK);

    uint64_t pending_start_time = 0;

    printf("Ready. Use w/a/s/d to move, p to print status, q to quit.\n\n");

    while (running) {
        // Check for server messages
        check_acknowledgement(from_server_fd, pending_seq);

        // Check for timeout on pending move
        if (has_pending_move) {
            if (pending_start_time == 0) {
                pending_start_time = get_time_ms();
            } else if (get_time_ms() - pending_start_time > ACK_TIMEOUT_MS) {
                fprintf(stderr, "[ERROR] Move TIMEOUT: (%d, %d) -> (%d, %d) not acknowledged!\n",
                        grid_x, grid_z, pending_x, pending_z);
                moves_failed++;
                has_pending_move = 0;
                pending_start_time = 0;
            }
        } else {
            pending_start_time = 0;
        }

        // Check for keyboard input
        char c;
        if (read(STDIN_FILENO, &c, 1) == 1) {
            switch (c) {
                case 'w': case 'W':
                    move_player(to_server_fd, 0, -1, &seq);
                    break;
                case 's': case 'S':
                    move_player(to_server_fd, 0, 1, &seq);
                    break;
                case 'a': case 'A':
                    move_player(to_server_fd, -1, 0, &seq);
                    break;
                case 'd': case 'D':
                    move_player(to_server_fd, 1, 0, &seq);
                    break;
                case 'p': case 'P':
                    print_grid();
                    break;
                case 'q': case 'Q':
                    running = 0;
                    break;
            }
        }

        usleep(10000);  // 10ms
    }

    // Restore stdin
    fcntl(STDIN_FILENO, F_SETFL, flags);

    printf("\n\nFinal Statistics:\n");
    print_grid();

    close(to_server_fd);
    close(from_server_fd);

    return 0;
}
