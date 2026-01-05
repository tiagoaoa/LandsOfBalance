/*
 * Headless Bot Client - Player Companion
 * Joins the UDP game server, follows the player, and shoots fire arrows.
 *
 * Compile: gcc -o bot_client bot_client.c -lm
 * Run: ./bot_client [player_id] [server_ip] [port]
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <time.h>
#include <math.h>
#include <signal.h>
#include <errno.h>

#define DEFAULT_PORT 7777
#define DEFAULT_SERVER "127.0.0.1"
#define UPDATE_INTERVAL_MS 16  // 60 Hz
#define ARROW_COOLDOWN_MS 2000  // Shoot every 2 seconds

// Follow distance settings
#define MIN_FOLLOW_DIST 2.0f   // Minimum distance to player
#define MAX_FOLLOW_DIST 10.0f  // Maximum distance to player
#define ARROW_AIM_HEIGHT 5.0f  // Aim this many meters above target for visible arc

// Packet types - MUST match Godot protocol.gd MsgType enum
#define PKT_JOIN         1   // MSG_JOIN
#define PKT_JOIN_ACK     2   // MSG_JOIN_ACK
#define PKT_LEAVE        3   // MSG_LEAVE
#define PKT_WORLD_STATE  4   // MSG_STATE
#define PKT_UPDATE       5   // MSG_MOVE
#define PKT_ACK          6   // MSG_ACK
#define PKT_PING         7   // MSG_PING
#define PKT_PONG         8   // MSG_PONG
#define PKT_ARROW_SPAWN  11  // MSG_ARROW_SPAWN
#define PKT_ARROW_HIT    12  // MSG_ARROW_HIT

// Player states - match protocol.gd PlayerState
#define STATE_IDLE        0
#define STATE_WALKING     1
#define STATE_RUNNING     2
#define STATE_ATTACKING   3
#define STATE_BLOCKING    4
#define STATE_JUMPING     5
#define STATE_CASTING     6
#define STATE_DRAWING_BOW 7
#define STATE_HOLDING_BOW 8

#pragma pack(push, 1)

typedef struct {
    uint32_t player_id;      // 4 bytes
    float pos_x, pos_y, pos_z; // 12 bytes
    float rot_y;             // 4 bytes
    uint8_t state;           // 1 byte
    uint8_t combat_mode;     // 1 byte
    uint8_t character_class; // 1 byte
    float health;            // 4 bytes
    char anim_name[32];      // 32 bytes
    uint8_t active;          // 1 byte
} PlayerData;

// Network packet header (9 bytes - MUST match Godot protocol.gd MsgHeader)
typedef struct {
    uint8_t type;         // 1 byte - MsgType enum
    uint32_t sequence;    // 4 bytes - Message sequence number
    uint32_t player_id;   // 4 bytes - 0 = server, else player_id
} PacketHeader;

typedef struct {
    PacketHeader header;
    char player_name[32];
} JoinPacket;

typedef struct {
    PacketHeader header;
    PlayerData data;
} UpdatePacket;

// World state packet (server -> client)
typedef struct {
    PacketHeader header;
    uint32_t state_seq;
    uint8_t player_count;
    PlayerData players[32];
} WorldStatePacket;

typedef struct {
    PacketHeader header;
    uint32_t assigned_id;
    PlayerData data;
} JoinAckPacket;

// Arrow spawn packet - must match Godot protocol.gd ArrowData (33 bytes after header)
typedef struct {
    PacketHeader header;       // 9 bytes
    uint32_t arrow_id;         // 4 bytes
    uint32_t shooter_id;       // 4 bytes - must be after arrow_id
    float pos_x, pos_y, pos_z; // 12 bytes
    float dir_x, dir_y, dir_z; // 12 bytes
    uint8_t active;            // 1 byte
} ArrowSpawnPacket;  // Total: 42 bytes

// Arrow hit packet
typedef struct {
    PacketHeader header;
    uint32_t arrow_id;
    float hit_x, hit_y, hit_z;
    uint32_t hit_entity_id;
} ArrowHitPacket;

#pragma pack(pop)

static volatile int running = 1;
static int bot_id = 1;
static uint32_t my_player_id = 0;
static uint32_t sequence = 0;
static uint32_t arrow_id_counter = 0;

// Bot state
static float pos_x = 0.0f, pos_y = 1.0f, pos_z = 10.0f;
static float rot_y = 0.0f;
static float move_speed = 5.0f;

// Player tracking (the human player we follow)
static float player_x = 0.0f, player_y = 1.0f, player_z = 0.0f;
static uint32_t player_id_to_follow = 0;  // 0 = not found yet
static float target_follow_dist = 5.0f;   // Random distance to maintain

// Combat state
typedef enum {
    BOT_STATE_FOLLOWING,    // Following the player
    BOT_STATE_AIMING,       // Drawing bow
    BOT_STATE_SHOOTING,     // Releasing arrow
    BOT_STATE_COOLDOWN      // Waiting for next shot
} BotCombatState;

static BotCombatState combat_state = BOT_STATE_FOLLOWING;
static uint64_t state_start_time = 0;
static uint64_t last_arrow_time = 0;

void signal_handler(int sig) {
    (void)sig;
    printf("\nBot shutting down...\n");
    running = 0;
}

uint64_t get_time_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000ULL + ts.tv_nsec / 1000000ULL;
}

float distance_to_player(void) {
    float dx = player_x - pos_x;
    float dz = player_z - pos_z;
    return sqrtf(dx * dx + dz * dz);
}

float angle_to_player(void) {
    float dx = player_x - pos_x;
    float dz = player_z - pos_z;
    // atan2(x, z) for Godot's coordinate system (Z forward)
    return atan2f(-dx, -dz);  // Negate to face towards target
}

// Get a random float between min and max
float random_range(float min_val, float max_val) {
    return min_val + ((float)rand() / RAND_MAX) * (max_val - min_val);
}

void send_join(int sock, struct sockaddr_in *server_addr) {
    JoinPacket pkt;
    memset(&pkt, 0, sizeof(pkt));

    pkt.header.type = PKT_JOIN;
    pkt.header.player_id = 0;
    pkt.header.sequence = ++sequence;
    snprintf(pkt.player_name, sizeof(pkt.player_name), "Hunter_%d", bot_id);

    sendto(sock, &pkt, sizeof(pkt), 0,
           (struct sockaddr*)server_addr, sizeof(*server_addr));

    printf("[Bot %d] Sent JOIN request as '%s'\n", bot_id, pkt.player_name);
}

void send_update(int sock, struct sockaddr_in *server_addr, uint8_t state, const char *anim) {
    if (my_player_id == 0) return;

    UpdatePacket pkt;
    memset(&pkt, 0, sizeof(pkt));

    pkt.header.type = PKT_UPDATE;
    pkt.header.player_id = my_player_id;
    pkt.header.sequence = ++sequence;

    pkt.data.player_id = my_player_id;
    pkt.data.pos_x = pos_x;
    pkt.data.pos_y = pos_y;
    pkt.data.pos_z = pos_z;
    pkt.data.rot_y = rot_y;
    pkt.data.state = state;
    pkt.data.combat_mode = 1;
    pkt.data.character_class = 2;  // Archer class
    pkt.data.health = 100.0f;
    strncpy(pkt.data.anim_name, anim, 31);
    pkt.data.active = 1;

    sendto(sock, &pkt, sizeof(pkt), 0,
           (struct sockaddr*)server_addr, sizeof(*server_addr));
}

void send_arrow(int sock, struct sockaddr_in *server_addr) {
    if (my_player_id == 0) return;

    ArrowSpawnPacket pkt;
    memset(&pkt, 0, sizeof(pkt));

    pkt.header.type = PKT_ARROW_SPAWN;
    pkt.header.player_id = my_player_id;
    pkt.header.sequence = ++sequence;

    pkt.arrow_id = (my_player_id << 16) | (++arrow_id_counter);
    pkt.shooter_id = my_player_id;
    pkt.active = 1;

    // Arrow spawns at bot position + forward offset + height
    float forward_x = sinf(rot_y);
    float forward_z = cosf(rot_y);
    pkt.pos_x = pos_x + forward_x * 1.0f;
    pkt.pos_y = pos_y + 1.5f;  // Chest height
    pkt.pos_z = pos_z + forward_z * 1.0f;

    // Shoot forward with a high arc (aim high for visibility)
    // Add random spread to make it interesting
    float spread = random_range(-0.2f, 0.2f);
    float dx = forward_x + spread;
    float dy = 0.5f;  // Aim upward at ~30 degree angle
    float dz = forward_z + spread;
    float len = sqrtf(dx*dx + dy*dy + dz*dz);
    if (len > 0.01f) {
        pkt.dir_x = dx / len;
        pkt.dir_y = dy / len;
        pkt.dir_z = dz / len;
    } else {
        pkt.dir_x = forward_x;
        pkt.dir_y = 0.5f;
        pkt.dir_z = forward_z;
    }

    sendto(sock, &pkt, sizeof(pkt), 0,
           (struct sockaddr*)server_addr, sizeof(*server_addr));

    printf("[Bot %d] FIRE! Arrow %u at (%.1f, %.1f, %.1f) -> dir (%.2f, %.2f, %.2f)\n",
           bot_id, pkt.arrow_id, pkt.pos_x, pkt.pos_y, pkt.pos_z,
           pkt.dir_x, pkt.dir_y, pkt.dir_z);
}

void send_leave(int sock, struct sockaddr_in *server_addr) {
    if (my_player_id == 0) return;

    PacketHeader pkt;
    pkt.type = PKT_LEAVE;
    pkt.player_id = my_player_id;
    pkt.sequence = ++sequence;

    sendto(sock, &pkt, sizeof(pkt), 0,
           (struct sockaddr*)server_addr, sizeof(*server_addr));

    printf("[Bot %d] Sent LEAVE\n", bot_id);
}

void receive_packets(int sock) {
    char buffer[2048];
    struct sockaddr_in from_addr;
    socklen_t from_len = sizeof(from_addr);

    ssize_t len = recvfrom(sock, buffer, sizeof(buffer), MSG_DONTWAIT,
                           (struct sockaddr*)&from_addr, &from_len);

    if (len < (ssize_t)sizeof(PacketHeader)) return;

    PacketHeader *header = (PacketHeader*)buffer;

    if (header->type == PKT_JOIN_ACK && len >= (ssize_t)sizeof(JoinAckPacket)) {
        JoinAckPacket *ack = (JoinAckPacket*)buffer;
        my_player_id = ack->assigned_id;
        pos_x = ack->data.pos_x;
        pos_y = ack->data.pos_y;
        pos_z = ack->data.pos_z;
        // Pick a random follow distance
        target_follow_dist = random_range(MIN_FOLLOW_DIST, MAX_FOLLOW_DIST);
        printf("[Bot %d] Received JOIN_ACK - Assigned ID: %u at (%.1f, %.1f, %.1f)\n",
               bot_id, my_player_id, pos_x, pos_y, pos_z);
        printf("[Bot %d] Will follow player at %.1fm distance\n", bot_id, target_follow_dist);
    }
    else if (header->type == PKT_WORLD_STATE) {
        // Parse world state to find player to follow
        size_t offset = sizeof(PacketHeader);
        if (len < (ssize_t)(offset + 5)) return;  // Need state_seq + player_count

        // Skip state_seq (4 bytes)
        offset += 4;
        uint8_t player_count = *(uint8_t*)(buffer + offset);
        offset += 1;

        // Look through all players
        for (int i = 0; i < player_count && offset + sizeof(PlayerData) <= (size_t)len; i++) {
            PlayerData *pd = (PlayerData*)(buffer + offset);
            offset += sizeof(PlayerData);

            // Skip ourselves
            if (pd->player_id == my_player_id) continue;

            // Found another player - follow them!
            if (player_id_to_follow == 0) {
                player_id_to_follow = pd->player_id;
                printf("[Bot %d] Now following player %u\n", bot_id, player_id_to_follow);
            }

            // Update tracked player position
            if (pd->player_id == player_id_to_follow) {
                player_x = pd->pos_x;
                player_y = pd->pos_y;
                player_z = pd->pos_z;
            }
        }
    }
}

void update_bot(int sock, struct sockaddr_in *server_addr, float delta) {
    uint64_t now = get_time_ms();
    float dist = distance_to_player();

    // No player to follow yet - just idle
    if (player_id_to_follow == 0) {
        send_update(sock, server_addr, STATE_IDLE, "Idle");
        return;
    }

    // Always face the direction we're moving (or the player if close)
    rot_y = angle_to_player();

    switch (combat_state) {
        case BOT_STATE_FOLLOWING:
            // Follow the player, maintaining target distance
            if (dist > target_follow_dist + 1.0f) {
                // Too far - run towards player
                float dx = player_x - pos_x;
                float dz = player_z - pos_z;
                float len = sqrtf(dx*dx + dz*dz);
                if (len > 0.1f) {
                    pos_x += (dx / len) * move_speed * delta;
                    pos_z += (dz / len) * move_speed * delta;
                }
                send_update(sock, server_addr, STATE_RUNNING, "Run");
            } else if (dist < target_follow_dist - 1.0f) {
                // Too close - back up a bit
                float dx = player_x - pos_x;
                float dz = player_z - pos_z;
                float len = sqrtf(dx*dx + dz*dz);
                if (len > 0.1f) {
                    pos_x -= (dx / len) * move_speed * 0.5f * delta;
                    pos_z -= (dz / len) * move_speed * 0.5f * delta;
                }
                send_update(sock, server_addr, STATE_WALKING, "Walk");
            } else {
                // Good distance - shoot an arrow!
                combat_state = BOT_STATE_AIMING;
                state_start_time = now;
            }
            break;

        case BOT_STATE_AIMING:
            // Draw bow animation (500ms)
            send_update(sock, server_addr, STATE_DRAWING_BOW, "Attack");
            if (now - state_start_time >= 500) {
                combat_state = BOT_STATE_SHOOTING;
                state_start_time = now;
            }
            break;

        case BOT_STATE_SHOOTING:
            // Release arrow
            send_arrow(sock, server_addr);
            send_update(sock, server_addr, STATE_ATTACKING, "Attack");
            combat_state = BOT_STATE_COOLDOWN;
            state_start_time = now;
            last_arrow_time = now;
            break;

        case BOT_STATE_COOLDOWN:
            // Wait for cooldown, then go back to following
            send_update(sock, server_addr, STATE_IDLE, "Idle");
            if (now - state_start_time >= 1500) {
                combat_state = BOT_STATE_FOLLOWING;
                // Pick a new random follow distance occasionally
                if (rand() % 3 == 0) {
                    target_follow_dist = random_range(MIN_FOLLOW_DIST, MAX_FOLLOW_DIST);
                }
                state_start_time = now;
            }
            break;
    }
}

int main(int argc, char *argv[]) {
    const char *server_ip = DEFAULT_SERVER;
    int server_port = DEFAULT_PORT;

    if (argc > 1) bot_id = atoi(argv[1]);
    if (argc > 2) server_ip = argv[2];
    if (argc > 3) server_port = atoi(argv[3]);

    srand(time(NULL) + bot_id);

    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    printf("===========================================\n");
    printf("  Player Companion Bot #%d\n", bot_id);
    printf("===========================================\n");
    printf("Server: %s:%d\n", server_ip, server_port);
    printf("Follow distance: %.1f-%.1fm\n", MIN_FOLLOW_DIST, MAX_FOLLOW_DIST);
    printf("Press Ctrl+C to stop\n");
    printf("===========================================\n\n");

    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) {
        perror("socket");
        return 1;
    }

    struct sockaddr_in server_addr;
    memset(&server_addr, 0, sizeof(server_addr));
    server_addr.sin_family = AF_INET;
    server_addr.sin_port = htons(server_port);
    inet_pton(AF_INET, server_ip, &server_addr.sin_addr);

    printf("[Bot %d] Waiting 1 second before joining...\n", bot_id);
    sleep(1);

    send_join(sock, &server_addr);

    uint64_t last_update = get_time_ms();

    while (running) {
        uint64_t now = get_time_ms();

        receive_packets(sock);

        if (now - last_update >= UPDATE_INTERVAL_MS) {
            float delta = (now - last_update) / 1000.0f;
            last_update = now;

            if (my_player_id != 0) {
                update_bot(sock, &server_addr, delta);
            }
        }

        usleep(1000);
    }

    send_leave(sock, &server_addr);
    close(sock);
    printf("[Bot %d] Disconnected\n", bot_id);

    return 0;
}
