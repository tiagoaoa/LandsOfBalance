/*
 * FIFO Automated Headless Test
 * Sends random moves and verifies server acknowledgements
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <math.h>

#define FIFO_PATH_PREFIX "/tmp/lob_"
#define MAX_PLAYERS 4
#define NUM_MOVES 10
#define READ_TIMEOUT_MS 2000

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

uint64_t get_time_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000ULL + ts.tv_nsec / 1000000ULL;
}

int main(int argc, char *argv[]) {
    int player_id = argc > 1 ? atoi(argv[1]) : 1;

    srand(time(NULL));

    printf("=== FIFO Automated Test ===\n");
    printf("Player ID: %d\n", player_id);
    printf("Moves: %d\n\n", NUM_MOVES);

    char to_server_path[128], from_server_path[128];
    snprintf(to_server_path, sizeof(to_server_path),
             "%splayer%d_to_server", FIFO_PATH_PREFIX, player_id);
    snprintf(from_server_path, sizeof(from_server_path),
             "%sserver_to_player%d", FIFO_PATH_PREFIX, player_id);

    printf("Opening FIFOs...\n");
    printf("  Write: %s\n", to_server_path);
    printf("  Read:  %s\n", from_server_path);

    // Open write FIFO
    int to_fd = open(to_server_path, O_WRONLY | O_NONBLOCK);
    if (to_fd < 0) {
        // Try without O_NONBLOCK
        to_fd = open(to_server_path, O_WRONLY);
    }
    if (to_fd < 0) {
        fprintf(stderr, "ERROR: Cannot open write FIFO: %s\n", strerror(errno));
        return 1;
    }
    printf("  Write FIFO opened (fd=%d)\n", to_fd);

    // Open read FIFO
    int from_fd = open(from_server_path, O_RDONLY | O_NONBLOCK);
    if (from_fd < 0) {
        fprintf(stderr, "ERROR: Cannot open read FIFO: %s\n", strerror(errno));
        close(to_fd);
        return 1;
    }
    printf("  Read FIFO opened (fd=%d)\n", from_fd);
    printf("\nConnected!\n\n");

    int grid_x = 0, grid_z = 0;
    int confirmed_x = 0, confirmed_z = 0;
    int acks = 0, failures = 0;

    for (int move = 0; move < NUM_MOVES; move++) {
        // Random direction
        int dx = (rand() % 3) - 1;  // -1, 0, 1
        int dz = (rand() % 3) - 1;
        if (dx == 0 && dz == 0) dx = 1;  // Ensure movement

        int new_x = grid_x + dx;
        int new_z = grid_z + dz;

        printf("[%d] SEND: (%d,%d) -> (%d,%d)\n", move+1, grid_x, grid_z, new_x, new_z);

        // Build and send message
        FifoMessage msg;
        memset(&msg, 0, sizeof(msg));
        msg.header.msg_type = 1;  // MSG_PLAYER_UPDATE
        msg.header.player_count = 1;
        msg.header.sequence = move + 1;
        msg.players[0].player_id = player_id;
        msg.players[0].x = (float)new_x;
        msg.players[0].y = 0.0f;
        msg.players[0].z = (float)new_z;
        msg.players[0].active = 1;
        msg.players[0].state = 1;
        msg.players[0].combat_mode = 1;
        msg.players[0].health = 100.0f;
        strncpy(msg.players[0].anim_name, "Walk", 32);

        ssize_t written = write(to_fd, &msg, sizeof(msg));
        printf("     Wrote %zd bytes (expected %zu)\n", written, sizeof(msg));

        if (written != sizeof(msg)) {
            fprintf(stderr, "     ERROR: Write failed: %s\n", strerror(errno));
            failures++;
            continue;
        }

        // Wait for acknowledgement
        uint64_t start = get_time_ms();
        int got_ack = 0;

        while (get_time_ms() - start < READ_TIMEOUT_MS) {
            FifoMessage resp;
            ssize_t bytes = read(from_fd, &resp, sizeof(resp));

            if (bytes == sizeof(resp)) {
                printf("     RECV: type=%d count=%d seq=%u\n",
                       resp.header.msg_type, resp.header.player_count, resp.header.sequence);

                if (resp.header.msg_type == 2) {  // MSG_GLOBAL_STATE
                    for (int i = 0; i < resp.header.player_count; i++) {
                        if (resp.players[i].player_id == (uint32_t)player_id) {
                            int sx = (int)roundf(resp.players[i].x);
                            int sz = (int)roundf(resp.players[i].z);
                            printf("     Server position: (%d, %d)\n", sx, sz);

                            if (sx == new_x && sz == new_z) {
                                printf("     ACK: Position confirmed!\n");
                                confirmed_x = sx;
                                confirmed_z = sz;
                                grid_x = new_x;
                                grid_z = new_z;
                                got_ack = 1;
                                acks++;
                            }
                            break;
                        }
                    }
                }
                if (got_ack) break;
            } else if (bytes > 0) {
                printf("     RECV: partial %zd bytes\n", bytes);
            }
            usleep(50000);  // 50ms
        }

        if (!got_ack) {
            printf("     TIMEOUT: No acknowledgement received\n");
            failures++;
        }

        printf("\n");
        usleep(300000);  // 300ms between moves
    }

    printf("=== Test Complete ===\n");
    printf("Final position: (%d, %d)\n", grid_x, grid_z);
    printf("Confirmed:      (%d, %d)\n", confirmed_x, confirmed_z);
    printf("Acks: %d, Failures: %d\n", acks, failures);
    printf("Result: %s\n", failures == 0 ? "PASS" : "FAIL");

    close(to_fd);
    close(from_fd);

    return failures > 0 ? 1 : 0;
}
