/*
 * Douglass The Keeper - Multiplayer UDP Server
 *
 * A simple UDP game server that handles multiple players.
 * Each client gets a dedicated thread for I/O processing.
 *
 * Compile: gcc -o game_server game_server.c -lpthread -lm
 * Run: ./game_server [port]
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <time.h>
#include <math.h>
#include <signal.h>
#include <errno.h>

#define DEFAULT_PORT 7777
#define MAX_PLAYERS 32
#define MAX_ENTITIES 64
#define BUFFER_SIZE 2048
#define PLAYER_TIMEOUT_SEC 10
#define BROADCAST_INTERVAL_MS 50   // 20 Hz (slower to avoid buffer overflow)

// Player state flags
#define STATE_IDLE      0
#define STATE_WALKING   1
#define STATE_RUNNING   2
#define STATE_ATTACKING 3
#define STATE_BLOCKING  4
#define STATE_JUMPING   5

// Packet types - MUST match Godot protocol.gd MsgType enum
#define PKT_JOIN         1   // MSG_JOIN
#define PKT_JOIN_ACK     2   // MSG_JOIN_ACK
#define PKT_LEAVE        3   // MSG_LEAVE
#define PKT_WORLD_STATE  4   // MSG_STATE
#define PKT_UPDATE       5   // MSG_MOVE
#define PKT_ACK          6   // MSG_ACK
#define PKT_PING         7   // MSG_PING
#define PKT_PONG         8   // MSG_PONG
#define PKT_ENTITY_STATE 9   // MSG_ENTITY_STATE
#define PKT_ENTITY_DAMAGE 10 // MSG_ENTITY_DAMAGE
#define PKT_ARROW_SPAWN  11  // MSG_ARROW_SPAWN
#define PKT_ARROW_HIT    12  // MSG_ARROW_HIT
#define PKT_HOST_CHANGE  13  // MSG_HOST_CHANGE
#define PKT_HEARTBEAT    14  // MSG_HEARTBEAT
#define PKT_SPECTATE     15  // MSG_SPECTATE
#define PKT_SPECTATE_ACK 16  // MSG_SPECTATE_ACK

// Entity types
#define ENTITY_BOBBA     0
#define ENTITY_DRAGON    1
#define ENTITY_ARROW     2

#pragma pack(push, 1)

// Player position and state (60 bytes - must match Godot protocol.gd)
typedef struct {
    uint32_t player_id;      // 4 bytes
    float pos_x, pos_y, pos_z; // 12 bytes
    float rot_y;             // 4 bytes - Rotation around Y axis
    uint8_t state;           // 1 byte
    uint8_t combat_mode;     // 1 byte - 0 = unarmed, 1 = armed
    uint8_t character_class; // 1 byte - 0 = paladin, 1 = archer
    float health;            // 4 bytes
    char anim_name[32];      // 32 bytes - Current animation name
    uint8_t active;          // 1 byte
} PlayerData;

// Network packet header (9 bytes - MUST match Godot protocol.gd MsgHeader)
typedef struct {
    uint8_t type;         // 1 byte - MsgType enum
    uint32_t sequence;    // 4 bytes - Message sequence number
    uint32_t player_id;   // 4 bytes - 0 = server, else player_id
} PacketHeader;

// Join packet (client -> server)
typedef struct {
    PacketHeader header;
    char player_name[32];
} JoinPacket;

// Update packet (client -> server)
typedef struct {
    PacketHeader header;
    PlayerData data;
} UpdatePacket;

// Join ACK packet (server -> client)
typedef struct {
    PacketHeader header;
    uint32_t assigned_id;
    PlayerData data;
} JoinAckPacket;

// World state packet (server -> client) - MUST match Godot protocol.gd
typedef struct {
    PacketHeader header;
    uint32_t state_seq;        // 4 bytes - State sequence number
    uint8_t player_count;      // 1 byte - Number of players
    PlayerData players[MAX_PLAYERS];
} WorldStatePacket;

// Entity data for network sync (Bobba, Dragon)
typedef struct {
    uint8_t entity_type;
    uint32_t entity_id;
    float pos_x, pos_y, pos_z;
    float rot_y;
    uint8_t state;
    float health;
    uint32_t extra1;  // Entity-specific (e.g., lap_count for Dragon)
    float extra2;     // Entity-specific (e.g., patrol_angle for Dragon)
} EntityData;

// Entity state packet (host -> server -> clients)
typedef struct {
    PacketHeader header;
    uint8_t entity_count;
    EntityData entities[MAX_ENTITIES];
} EntityStatePacket;

// Arrow spawn packet (client -> server -> other clients)
typedef struct {
    PacketHeader header;
    uint32_t arrow_id;
    float pos_x, pos_y, pos_z;
    float dir_x, dir_y, dir_z;
    uint32_t shooter_id;
} ArrowSpawnPacket;

// Arrow hit packet (client -> server -> other clients)
typedef struct {
    PacketHeader header;
    uint32_t arrow_id;
    float hit_x, hit_y, hit_z;
    uint32_t hit_entity_id;
} ArrowHitPacket;

// Entity damage packet (client -> server -> host)
typedef struct {
    PacketHeader header;
    uint32_t entity_id;
    float damage;
    uint32_t attacker_id;
} EntityDamagePacket;

#pragma pack(pop)

// Player info stored on server
typedef struct {
    uint32_t player_id;
    char name[32];
    struct sockaddr_in addr;
    time_t last_seen;
    PlayerData data;
    int active;
    pthread_t thread;
} Player;

// Spectator info (receives world state but doesn't play)
typedef struct {
    struct sockaddr_in addr;
    time_t last_seen;
    int active;
} Spectator;

#define MAX_SPECTATORS 32

// Global server state
static int server_socket = -1;
static Player players[MAX_PLAYERS];
static Spectator spectators[MAX_SPECTATORS];
static pthread_mutex_t players_mutex = PTHREAD_MUTEX_INITIALIZER;
static volatile int running = 1;
static uint32_t next_player_id = 1;
static uint32_t state_sequence = 0;  // Increments each broadcast

// Original spawn point
static float spawn_x = 0.0f;
static float spawn_y = 0.0f;
static float spawn_z = 0.0f;

void signal_handler(int sig) {
    printf("\nShutting down server...\n");
    running = 0;
}

// Generate random spawn position within 50m of original spawn
void generate_spawn_position(float *x, float *y, float *z) {
    float angle = ((float)rand() / RAND_MAX) * 2.0f * M_PI;
    float distance = ((float)rand() / RAND_MAX) * 2.0f;

    *x = spawn_x + cos(angle) * distance;
    *y = spawn_y;  // Keep same Y level
    *z = spawn_z + sin(angle) * distance;
}

// Find player by address
Player* find_player_by_addr(struct sockaddr_in *addr) {
    for (int i = 0; i < MAX_PLAYERS; i++) {
        if (players[i].active &&
            players[i].addr.sin_addr.s_addr == addr->sin_addr.s_addr &&
            players[i].addr.sin_port == addr->sin_port) {
            return &players[i];
        }
    }
    return NULL;
}

// Find player by ID
Player* find_player_by_id(uint32_t id) {
    for (int i = 0; i < MAX_PLAYERS; i++) {
        if (players[i].active && players[i].player_id == id) {
            return &players[i];
        }
    }
    return NULL;
}

// Find free player slot
int find_free_slot() {
    for (int i = 0; i < MAX_PLAYERS; i++) {
        if (!players[i].active) {
            return i;
        }
    }
    return -1;
}

// Count active players
int count_active_players() {
    int count = 0;
    for (int i = 0; i < MAX_PLAYERS; i++) {
        if (players[i].active) count++;
    }
    return count;
}

// Broadcast world state to all players
void broadcast_world_state() {
    WorldStatePacket packet;
    memset(&packet, 0, sizeof(packet));

    packet.header.type = PKT_WORLD_STATE;
    packet.header.sequence = ++state_sequence;
    packet.header.player_id = 0;  // From server
    packet.state_seq = state_sequence;

    pthread_mutex_lock(&players_mutex);

    int count = 0;
    for (int i = 0; i < MAX_PLAYERS && count < MAX_PLAYERS; i++) {
        if (players[i].active) {
            packet.players[count] = players[i].data;
            count++;
        }
    }
    packet.player_count = count;

    // Send to all active players
    for (int i = 0; i < MAX_PLAYERS; i++) {
        if (players[i].active) {
            sendto(server_socket, &packet, sizeof(packet), 0,
                   (struct sockaddr*)&players[i].addr, sizeof(players[i].addr));
        }
    }

    // Send to all spectators
    for (int i = 0; i < MAX_SPECTATORS; i++) {
        if (spectators[i].active) {
            sendto(server_socket, &packet, sizeof(packet), 0,
                   (struct sockaddr*)&spectators[i].addr, sizeof(spectators[i].addr));
        }
    }

    pthread_mutex_unlock(&players_mutex);
}

// Handle join request
void handle_join(JoinPacket *pkt, struct sockaddr_in *client_addr) {
    pthread_mutex_lock(&players_mutex);

    // Remove from spectators if they were spectating
    for (int i = 0; i < MAX_SPECTATORS; i++) {
        if (spectators[i].active &&
            spectators[i].addr.sin_addr.s_addr == client_addr->sin_addr.s_addr &&
            spectators[i].addr.sin_port == client_addr->sin_port) {
            spectators[i].active = 0;
            printf("Spectator promoted to player\n");
            break;
        }
    }

    // Check if already connected
    Player *existing = find_player_by_addr(client_addr);
    if (existing) {
        printf("Player %s reconnected (ID: %u)\n", existing->name, existing->player_id);
        existing->last_seen = time(NULL);
        pthread_mutex_unlock(&players_mutex);
        return;
    }

    // Find free slot
    int slot = find_free_slot();
    if (slot < 0) {
        printf("Server full, rejecting player %s\n", pkt->player_name);
        pthread_mutex_unlock(&players_mutex);
        return;
    }

    // Initialize new player
    Player *player = &players[slot];
    memset(player, 0, sizeof(Player));

    player->player_id = next_player_id++;
    strncpy(player->name, pkt->player_name, sizeof(player->name) - 1);
    player->addr = *client_addr;
    player->last_seen = time(NULL);
    player->active = 1;

    // Set initial player data
    player->data.player_id = player->player_id;
    generate_spawn_position(&player->data.pos_x, &player->data.pos_y, &player->data.pos_z);
    player->data.rot_y = 0;
    player->data.state = STATE_IDLE;
    player->data.combat_mode = 1;  // Armed by default
    player->data.character_class = 1;  // Archer by default
    player->data.health = 100.0f;
    strncpy(player->data.anim_name, "Idle", sizeof(player->data.anim_name));
    player->data.active = 1;

    printf("Player %s joined (ID: %u) at position (%.1f, %.1f, %.1f) - Total players: %d\n",
           player->name, player->player_id,
           player->data.pos_x, player->data.pos_y, player->data.pos_z,
           count_active_players());
    fflush(stdout);

    // Send JOIN_ACK to the new player
    JoinAckPacket ack;
    memset(&ack, 0, sizeof(ack));
    ack.header.type = PKT_JOIN_ACK;
    ack.header.player_id = player->player_id;
    ack.header.sequence = (uint32_t)time(NULL);
    ack.assigned_id = player->player_id;
    ack.data = player->data;

    sendto(server_socket, &ack, sizeof(ack), 0,
           (struct sockaddr*)client_addr, sizeof(*client_addr));
    printf("Sent JOIN_ACK to player %u\n", player->player_id);
    fflush(stdout);

    // Send initial world state to new player
    pthread_mutex_unlock(&players_mutex);
    broadcast_world_state();
}

// Handle player update
void handle_update(UpdatePacket *pkt, struct sockaddr_in *client_addr) {
    pthread_mutex_lock(&players_mutex);

    Player *player = find_player_by_id(pkt->header.player_id);
    if (!player) {
        pthread_mutex_unlock(&players_mutex);
        return;
    }

    // Verify address matches
    if (player->addr.sin_addr.s_addr != client_addr->sin_addr.s_addr ||
        player->addr.sin_port != client_addr->sin_port) {
        pthread_mutex_unlock(&players_mutex);
        return;
    }

    // Update player data
    player->data = pkt->data;
    player->data.player_id = player->player_id;  // Ensure ID is preserved
    player->last_seen = time(NULL);

    pthread_mutex_unlock(&players_mutex);
}

// Handle spectate request
void handle_spectate(PacketHeader *hdr, struct sockaddr_in *client_addr) {
    pthread_mutex_lock(&players_mutex);

    // Check if already a spectator
    for (int i = 0; i < MAX_SPECTATORS; i++) {
        if (spectators[i].active &&
            spectators[i].addr.sin_addr.s_addr == client_addr->sin_addr.s_addr &&
            spectators[i].addr.sin_port == client_addr->sin_port) {
            spectators[i].last_seen = time(NULL);
            pthread_mutex_unlock(&players_mutex);
            return;
        }
    }

    // Find free slot
    int slot = -1;
    for (int i = 0; i < MAX_SPECTATORS; i++) {
        if (!spectators[i].active) {
            slot = i;
            break;
        }
    }

    if (slot < 0) {
        printf("Too many spectators, rejecting\n");
        pthread_mutex_unlock(&players_mutex);
        return;
    }

    // Add spectator
    spectators[slot].addr = *client_addr;
    spectators[slot].last_seen = time(NULL);
    spectators[slot].active = 1;

    printf("Spectator connected from %s:%d\n",
           inet_ntoa(client_addr->sin_addr), ntohs(client_addr->sin_port));
    fflush(stdout);

    // Send SPECTATE_ACK
    PacketHeader ack;
    ack.type = PKT_SPECTATE_ACK;
    ack.sequence = hdr->sequence;
    ack.player_id = 0;
    sendto(server_socket, &ack, sizeof(ack), 0,
           (struct sockaddr*)client_addr, sizeof(*client_addr));
    printf("Sent SPECTATE_ACK\n");
    fflush(stdout);

    pthread_mutex_unlock(&players_mutex);
}

// Handle player leave
void handle_leave(PacketHeader *hdr, struct sockaddr_in *client_addr) {
    pthread_mutex_lock(&players_mutex);

    Player *player = find_player_by_id(hdr->player_id);
    if (player) {
        printf("Player %s left (ID: %u)\n", player->name, player->player_id);
        player->active = 0;
    }

    pthread_mutex_unlock(&players_mutex);
    broadcast_world_state();
}

// Cleanup timed out players
void cleanup_inactive_players() {
    time_t now = time(NULL);

    pthread_mutex_lock(&players_mutex);

    for (int i = 0; i < MAX_PLAYERS; i++) {
        if (players[i].active && (now - players[i].last_seen) > PLAYER_TIMEOUT_SEC) {
            printf("Player %s timed out (ID: %u)\n", players[i].name, players[i].player_id);
            players[i].active = 0;
        }
    }

    pthread_mutex_unlock(&players_mutex);
}

// Relay entity state from host to all other clients
void relay_entity_state(void *packet, size_t len, struct sockaddr_in *sender_addr) {
    pthread_mutex_lock(&players_mutex);

    for (int i = 0; i < MAX_PLAYERS; i++) {
        if (players[i].active) {
            // Skip the sender (host)
            if (players[i].addr.sin_addr.s_addr == sender_addr->sin_addr.s_addr &&
                players[i].addr.sin_port == sender_addr->sin_port) {
                continue;
            }
            sendto(server_socket, packet, len, 0,
                   (struct sockaddr*)&players[i].addr, sizeof(players[i].addr));
        }
    }

    pthread_mutex_unlock(&players_mutex);
}

// Relay arrow spawn to all clients except sender
void relay_arrow_spawn(ArrowSpawnPacket *pkt, size_t len, struct sockaddr_in *sender_addr) {
    pthread_mutex_lock(&players_mutex);

    printf("Relaying arrow spawn (id=%u) from player %u to %d clients\n",
           pkt->arrow_id, pkt->shooter_id, count_active_players() - 1);
    fflush(stdout);

    for (int i = 0; i < MAX_PLAYERS; i++) {
        if (players[i].active) {
            // Skip the sender
            if (players[i].addr.sin_addr.s_addr == sender_addr->sin_addr.s_addr &&
                players[i].addr.sin_port == sender_addr->sin_port) {
                continue;
            }
            sendto(server_socket, pkt, len, 0,
                   (struct sockaddr*)&players[i].addr, sizeof(players[i].addr));
        }
    }

    pthread_mutex_unlock(&players_mutex);
}

// Relay arrow hit to all clients except sender
void relay_arrow_hit(ArrowHitPacket *pkt, size_t len, struct sockaddr_in *sender_addr) {
    pthread_mutex_lock(&players_mutex);

    printf("Relaying arrow hit (id=%u) at (%.1f, %.1f, %.1f)\n",
           pkt->arrow_id, pkt->hit_x, pkt->hit_y, pkt->hit_z);
    fflush(stdout);

    for (int i = 0; i < MAX_PLAYERS; i++) {
        if (players[i].active) {
            // Skip the sender
            if (players[i].addr.sin_addr.s_addr == sender_addr->sin_addr.s_addr &&
                players[i].addr.sin_port == sender_addr->sin_port) {
                continue;
            }
            sendto(server_socket, pkt, len, 0,
                   (struct sockaddr*)&players[i].addr, sizeof(players[i].addr));
        }
    }

    pthread_mutex_unlock(&players_mutex);
}

// Relay entity damage to host (first/lowest ID player)
void relay_entity_damage(EntityDamagePacket *pkt, size_t len, struct sockaddr_in *sender_addr) {
    pthread_mutex_lock(&players_mutex);

    // Find host (lowest player ID)
    Player *host = NULL;
    uint32_t lowest_id = UINT32_MAX;
    for (int i = 0; i < MAX_PLAYERS; i++) {
        if (players[i].active && players[i].player_id < lowest_id) {
            lowest_id = players[i].player_id;
            host = &players[i];
        }
    }

    if (host) {
        printf("Relaying entity damage (entity=%u, damage=%.1f) to host %u\n",
               pkt->entity_id, pkt->damage, host->player_id);
        fflush(stdout);
        sendto(server_socket, pkt, len, 0,
               (struct sockaddr*)&host->addr, sizeof(host->addr));
    }

    pthread_mutex_unlock(&players_mutex);
}

// Broadcast thread - sends world state periodically
void* broadcast_thread(void *arg) {
    while (running) {
        broadcast_world_state();
        usleep(BROADCAST_INTERVAL_MS * 1000);

        // Cleanup every second
        static int cleanup_counter = 0;
        if (++cleanup_counter >= (1000 / BROADCAST_INTERVAL_MS)) {
            cleanup_inactive_players();
            cleanup_counter = 0;
        }
    }
    return NULL;
}

// Main receive loop
void* receive_thread(void *arg) {
    char buffer[BUFFER_SIZE];
    struct sockaddr_in client_addr;
    socklen_t addr_len = sizeof(client_addr);

    while (running) {
        ssize_t recv_len = recvfrom(server_socket, buffer, BUFFER_SIZE, 0,
                                     (struct sockaddr*)&client_addr, &addr_len);

        if (recv_len < 0) {
            if (errno == EINTR) continue;
            perror("recvfrom failed");
            continue;
        }

        if (recv_len < sizeof(PacketHeader)) {
            printf("Received invalid packet (too small: %zd bytes)\n", recv_len);
            fflush(stdout);
            continue;  // Invalid packet
        }

        PacketHeader *header = (PacketHeader*)buffer;
        printf("Received packet type %d from %s:%d (%zd bytes)\n",
               header->type, inet_ntoa(client_addr.sin_addr), ntohs(client_addr.sin_port), recv_len);
        fflush(stdout);

        switch (header->type) {
            case PKT_JOIN:
                if (recv_len >= sizeof(JoinPacket)) {
                    handle_join((JoinPacket*)buffer, &client_addr);
                }
                break;

            case PKT_UPDATE:
                if (recv_len >= sizeof(UpdatePacket)) {
                    handle_update((UpdatePacket*)buffer, &client_addr);
                }
                break;

            case PKT_LEAVE:
                handle_leave(header, &client_addr);
                break;

            case PKT_PING:
                // Respond with pong
                {
                    PacketHeader pong;
                    pong.type = PKT_PONG;
                    pong.player_id = header->player_id;
                    pong.sequence = header->sequence;
                    sendto(server_socket, &pong, sizeof(pong), 0,
                           (struct sockaddr*)&client_addr, addr_len);
                }
                break;

            case PKT_ENTITY_STATE:
                // Relay entity state from host to all other clients
                if (recv_len >= sizeof(PacketHeader) + 1) {
                    relay_entity_state(buffer, recv_len, &client_addr);
                }
                break;

            case PKT_ENTITY_DAMAGE:
                // Relay entity damage to host
                if (recv_len >= sizeof(EntityDamagePacket)) {
                    relay_entity_damage((EntityDamagePacket*)buffer, recv_len, &client_addr);
                }
                break;

            case PKT_ARROW_SPAWN:
                // Relay arrow spawn to all other clients
                if (recv_len >= sizeof(ArrowSpawnPacket)) {
                    relay_arrow_spawn((ArrowSpawnPacket*)buffer, recv_len, &client_addr);
                }
                break;

            case PKT_ARROW_HIT:
                // Relay arrow hit to all other clients
                if (recv_len >= sizeof(ArrowHitPacket)) {
                    relay_arrow_hit((ArrowHitPacket*)buffer, recv_len, &client_addr);
                }
                break;

            case PKT_SPECTATE:
                // Add as spectator (receive world state without playing)
                handle_spectate(header, &client_addr);
                break;

            default:
                printf("Unknown packet type: %d\n", header->type);
                break;
        }
    }
    return NULL;
}

int main(int argc, char *argv[]) {
    int port = DEFAULT_PORT;

    if (argc > 1) {
        port = atoi(argv[1]);
    }

    // Initialize random seed
    srand(time(NULL));

    // Setup signal handler
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    // Create UDP socket
    server_socket = socket(AF_INET, SOCK_DGRAM, 0);
    if (server_socket < 0) {
        perror("Failed to create socket");
        return 1;
    }

    // Allow address reuse
    int opt = 1;
    setsockopt(server_socket, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    // Bind to port
    struct sockaddr_in server_addr;
    memset(&server_addr, 0, sizeof(server_addr));
    server_addr.sin_family = AF_INET;
    server_addr.sin_addr.s_addr = INADDR_ANY;
    server_addr.sin_port = htons(port);

    if (bind(server_socket, (struct sockaddr*)&server_addr, sizeof(server_addr)) < 0) {
        perror("Failed to bind socket");
        close(server_socket);
        return 1;
    }

    // Initialize players array
    memset(players, 0, sizeof(players));

    printf("===========================================\n");
    printf("  Douglass The Keeper - Game Server\n");
    printf("===========================================\n");
    printf("Listening on UDP port %d\n", port);
    printf("Max players: %d\n", MAX_PLAYERS);
    printf("Broadcast interval: %d ms\n", BROADCAST_INTERVAL_MS);
    printf("Player timeout: %d seconds\n", PLAYER_TIMEOUT_SEC);
    printf("Press Ctrl+C to stop\n");
    printf("===========================================\n\n");
    fflush(stdout);

    // Start broadcast thread
    pthread_t broadcast_tid;
    pthread_create(&broadcast_tid, NULL, broadcast_thread, NULL);

    // Start receive thread (or run in main thread)
    receive_thread(NULL);

    // Cleanup
    pthread_join(broadcast_tid, NULL);
    close(server_socket);

    printf("Server stopped.\n");
    return 0;
}
