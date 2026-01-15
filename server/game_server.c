/*
 * Douglass The Keeper - Multiplayer UDP Server
 *
 * A simple UDP game server that handles multiple players.
 * Single-threaded event loop with non-blocking UDP socket.
 *
 * Compile: gcc -o game_server game_server.c -lm
 * Run: ./game_server [port]
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
#include <fcntl.h>

#define DEFAULT_PORT 7777
#define MAX_PLAYERS 32
#define MAX_ENTITIES 64
#define MAX_BOBBAS 4
#define BUFFER_SIZE 2048
#define PLAYER_TIMEOUT_SEC 10
#define BROADCAST_INTERVAL_MS 50   // 20 Hz (slower to avoid buffer overflow)
#define ENTITY_UPDATE_INTERVAL_MS 50  // 20 Hz for entity updates (same as world state)

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
#define PKT_PLAYER_DAMAGE 17 // MSG_PLAYER_DAMAGE - Server -> Client when entity hits player
#define PKT_GAME_RESTART  18 // MSG_GAME_RESTART - Bidirectional: request/broadcast game restart

// Entity types
#define ENTITY_BOBBA     0
#define ENTITY_DRAGON    1
#define ENTITY_ARROW     2

// Bobba states (must match protocol.gd BobbaState)
#define BOBBA_ROAMING    0
#define BOBBA_CHASING    1
#define BOBBA_ATTACKING  2
#define BOBBA_IDLE       3
#define BOBBA_STUNNED    4

// Bobba AI constants
#define BOBBA_DETECTION_RADIUS 10.0f
#define BOBBA_LOSE_RADIUS      20.0f
#define BOBBA_ATTACK_DISTANCE  2.0f
#define BOBBA_ROAM_SPEED       2.0f
#define BOBBA_CHASE_SPEED      5.0f
#define BOBBA_ROTATION_SPEED   5.0f
#define BOBBA_ROAM_CHANGE_TIME 3.0f
#define BOBBA_ATTACK_DURATION  1.5f
#define BOBBA_ATTACK_DAMAGE    70.0f
#define BOBBA_KNOCKBACK_FORCE  12.0f
#define BOBBA_HIT_WINDOW_START 0.3f  // 30% into attack animation
#define BOBBA_HIT_WINDOW_END   0.7f  // 70% into attack animation

// Dragon states (must match protocol.gd DragonState)
#define DRAGON_PATROL        0
#define DRAGON_FLYING_TO_LAND 1
#define DRAGON_LANDING       2
#define DRAGON_WAIT          3
#define DRAGON_TAKING_OFF    4
#define DRAGON_ATTACKING     5

// Dragon AI constants
#define DRAGON_PATROL_RADIUS  100.0f
#define DRAGON_PATROL_HEIGHT  80.0f
#define DRAGON_PATROL_SPEED   25.0f
#define DRAGON_LAPS_BEFORE_LANDING 2
#define DRAGON_WAIT_TIME      5.0f
#define DRAGON_ATTACK_RANGE   40.0f
#define DRAGON_LANDING_SPOT_X 0.0f
#define DRAGON_LANDING_SPOT_Y 5.0f
#define DRAGON_LANDING_SPOT_Z 50.0f

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

// Player damage packet (server -> client when entity hits player)
typedef struct {
    PacketHeader header;
    uint32_t target_player_id;
    float damage;
    uint32_t attacker_entity_id;
    float knockback_x, knockback_y, knockback_z;
} PlayerDamagePacket;

// Game restart packet (client -> server -> all clients)
typedef struct {
    PacketHeader header;
    uint32_t reason;  // 0 = player died, 1 = bobba died, 2 = manual restart
} GameRestartPacket;

#pragma pack(pop)

// Player info stored on server
typedef struct {
    uint32_t player_id;
    char name[32];
    struct sockaddr_in addr;
    time_t last_seen;
    PlayerData data;
    int active;
} Player;

// Spectator info (receives world state but doesn't play)
typedef struct {
    struct sockaddr_in addr;
    time_t last_seen;
    int active;
} Spectator;

#define MAX_SPECTATORS 32

// Server-side Bobba entity (AI runs on server)
typedef struct {
    uint32_t entity_id;
    float pos_x, pos_y, pos_z;
    float rot_y;
    uint8_t state;
    float health;
    int active;

    // AI state
    uint32_t target_player_id;  // 0 = no target
    float roam_dir_x, roam_dir_z;
    float roam_timer;
    float attack_timer;
    float attack_start_time;    // When attack started (for hit window calculation)
    float stun_timer;
    int has_hit_this_attack;    // True if already dealt damage this attack
} ServerBobba;

// Server-side Dragon entity (AI runs on server)
typedef struct {
    uint32_t entity_id;
    float pos_x, pos_y, pos_z;
    float rot_y;
    uint8_t state;
    float health;
    int active;

    // Patrol state
    float patrol_angle;          // Current angle in circular patrol
    float patrol_center_x, patrol_center_z;
    int laps_completed;

    // Landing/waiting state
    float wait_timer;
    float attack_timer;

    // Target player for attacks
    uint32_t target_player_id;
} ServerDragon;

#define MAX_DRAGONS 1

// Global server state
static int server_socket = -1;
static Player players[MAX_PLAYERS];
static Spectator spectators[MAX_SPECTATORS];
static ServerBobba bobbas[MAX_BOBBAS];
static ServerDragon dragons[MAX_DRAGONS];
static volatile int running = 1;
static uint32_t next_player_id = 1;
static uint32_t next_entity_id = 1;
static uint32_t state_sequence = 0;  // Increments each broadcast
static int test_multiplayer = 0;     // --test-multiplayer flag: disables enemy AI

// Original spawn point
static float spawn_x = 0.0f;
static float spawn_y = 0.0f;
static float spawn_z = 0.0f;

// Forward declarations
void send_player_damage(uint32_t target_player_id, float damage, uint32_t attacker_entity_id,
                        float knockback_x, float knockback_y, float knockback_z);
void broadcast_entity_state(void);
void broadcast_world_state(void);

void signal_handler(int sig) {
    printf("\nShutting down server...\n");
    running = 0;
}

// Spawn positions at foot of hills near the Tower of Hakutnas (-80, 0, -60)
static const float spawn_points[][3] = {
    { -60.0f, 2.0f, -80.0f },   // Near tower, foot of hills area
    { -40.0f, 2.0f, -100.0f },  // Between tower and TheHills
    { -80.0f, 2.0f, -40.0f },   // Other side of tower
};
static const int NUM_SPAWN_POINTS = 3;

// Generate random spawn position at foot of hills near tower
void generate_spawn_position(float *x, float *y, float *z) {
    // Pick a random spawn point
    int spawn_idx = rand() % NUM_SPAWN_POINTS;

    // Small random offset (within 8m radius)
    float angle = ((float)rand() / RAND_MAX) * 2.0f * M_PI;
    float distance = ((float)rand() / RAND_MAX) * 8.0f;

    *x = spawn_points[spawn_idx][0] + cos(angle) * distance;
    *y = spawn_points[spawn_idx][1];  // Keep at ground level
    *z = spawn_points[spawn_idx][2] + sin(angle) * distance;

    printf("Spawn position: point %d at (%.1f, %.1f, %.1f)\n", spawn_idx + 1, *x, *y, *z);
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

// =============================================================================
// BOBBA AI (Server-authoritative)
// =============================================================================

// Initialize a Bobba at a position
void spawn_bobba(float x, float y, float z) {

    for (int i = 0; i < MAX_BOBBAS; i++) {
        if (!bobbas[i].active) {
            memset(&bobbas[i], 0, sizeof(ServerBobba));
            bobbas[i].entity_id = next_entity_id++;
            bobbas[i].pos_x = x;
            bobbas[i].pos_y = y;
            bobbas[i].pos_z = z;
            bobbas[i].rot_y = 0;
            bobbas[i].state = BOBBA_ROAMING;
            bobbas[i].health = 100.0f;
            bobbas[i].active = 1;
            bobbas[i].target_player_id = 0;

            // Random initial roam direction
            float angle = ((float)rand() / RAND_MAX) * 2.0f * M_PI;
            bobbas[i].roam_dir_x = cos(angle);
            bobbas[i].roam_dir_z = sin(angle);
            bobbas[i].roam_timer = BOBBA_ROAM_CHANGE_TIME;

            printf("Spawned Bobba %u at (%.1f, %.1f, %.1f)\n",
                   bobbas[i].entity_id, x, y, z);
            fflush(stdout);
            break;
        }
    }

}

// Calculate distance between two 3D points
float distance_3d(float x1, float y1, float z1, float x2, float y2, float z2) {
    float dx = x2 - x1;
    float dy = y2 - y1;
    float dz = z2 - z1;
    return sqrt(dx*dx + dy*dy + dz*dz);
}

// Find nearest player to a position
Player* find_nearest_player(float x, float y, float z, float *out_distance) {
    Player *nearest = NULL;
    float min_dist = 999999.0f;

    for (int i = 0; i < MAX_PLAYERS; i++) {
        if (players[i].active) {
            float dist = distance_3d(x, y, z,
                                     players[i].data.pos_x,
                                     players[i].data.pos_y,
                                     players[i].data.pos_z);
            if (dist < min_dist) {
                min_dist = dist;
                nearest = &players[i];
            }
        }
    }

    if (out_distance) *out_distance = min_dist;
    return nearest;
}

// Pick a new random roam direction
void bobba_pick_roam_direction(ServerBobba *bobba) {
    float angle = ((float)rand() / RAND_MAX) * 2.0f * M_PI;
    bobba->roam_dir_x = cos(angle);
    bobba->roam_dir_z = sin(angle);
    bobba->roam_timer = BOBBA_ROAM_CHANGE_TIME;
}

// Update a single Bobba's AI
void update_bobba_ai(ServerBobba *bobba, float delta) {
    if (!bobba->active) return;

    // TEST_MULTIPLAYER mode: skip AI, just idle in place
    if (test_multiplayer) {
        bobba->state = BOBBA_IDLE;
        return;
    }

    // Handle stun timer
    if (bobba->stun_timer > 0) {
        bobba->stun_timer -= delta;
        if (bobba->stun_timer <= 0) {
            bobba->state = (bobba->target_player_id != 0) ? BOBBA_CHASING : BOBBA_ROAMING;
        }
        return;
    }

    // Handle attack timer
    if (bobba->state == BOBBA_ATTACKING) {
        bobba->attack_timer -= delta;

        // Calculate attack progress (0.0 to 1.0)
        float attack_progress = 1.0f - (bobba->attack_timer / bobba->attack_start_time);

        // Check if we're in the hit window and haven't hit yet
        if (!bobba->has_hit_this_attack &&
            attack_progress >= BOBBA_HIT_WINDOW_START &&
            attack_progress <= BOBBA_HIT_WINDOW_END &&
            bobba->target_player_id != 0) {

            // Check if target is still in range
            Player *target = find_player_by_id(bobba->target_player_id);
            if (target && target->active) {
                float dist = distance_3d(bobba->pos_x, bobba->pos_y, bobba->pos_z,
                                         target->data.pos_x, target->data.pos_y, target->data.pos_z);

                if (dist <= BOBBA_ATTACK_DISTANCE * 2.0f) {  // Slightly larger hit range
                    // Calculate knockback direction (from Bobba to player)
                    float dx = target->data.pos_x - bobba->pos_x;
                    float dy = 0.3f;  // Slight upward component
                    float dz = target->data.pos_z - bobba->pos_z;
                    float len = sqrt(dx*dx + dz*dz);
                    if (len > 0.01f) {
                        dx /= len;
                        dz /= len;
                    }

                    // Mark as hit and send damage
                    bobba->has_hit_this_attack = 1;
                    send_player_damage(bobba->target_player_id, BOBBA_ATTACK_DAMAGE,
                                       bobba->entity_id,
                                       dx * BOBBA_KNOCKBACK_FORCE,
                                       dy * BOBBA_KNOCKBACK_FORCE,
                                       dz * BOBBA_KNOCKBACK_FORCE);
                }
            }
        }

        if (bobba->attack_timer <= 0) {
            bobba->state = BOBBA_CHASING;
        }
        return;
    }

    // Find target
    float dist_to_target = 999999.0f;
    Player *target = NULL;

    if (bobba->target_player_id != 0) {
        target = find_player_by_id(bobba->target_player_id);
        if (target && target->active) {
            dist_to_target = distance_3d(bobba->pos_x, bobba->pos_y, bobba->pos_z,
                                         target->data.pos_x, target->data.pos_y, target->data.pos_z);
            // Lose target if too far
            if (dist_to_target > BOBBA_LOSE_RADIUS) {
                bobba->target_player_id = 0;
                target = NULL;
                bobba->state = BOBBA_ROAMING;
                bobba_pick_roam_direction(bobba);
            }
        } else {
            bobba->target_player_id = 0;
            target = NULL;
        }
    }

    // Look for new target if none
    if (bobba->target_player_id == 0) {
        Player *nearest = find_nearest_player(bobba->pos_x, bobba->pos_y, bobba->pos_z, &dist_to_target);
        if (nearest && dist_to_target <= BOBBA_DETECTION_RADIUS) {
            bobba->target_player_id = nearest->player_id;
            target = nearest;
            bobba->state = BOBBA_CHASING;
        }
    }

    // State machine
    switch (bobba->state) {
        case BOBBA_ROAMING: {
            // Move in roam direction
            bobba->pos_x += bobba->roam_dir_x * BOBBA_ROAM_SPEED * delta;
            bobba->pos_z += bobba->roam_dir_z * BOBBA_ROAM_SPEED * delta;

            // Face roam direction
            bobba->rot_y = atan2(bobba->roam_dir_x, bobba->roam_dir_z);

            // Change direction periodically
            bobba->roam_timer -= delta;
            if (bobba->roam_timer <= 0) {
                bobba_pick_roam_direction(bobba);
            }
            break;
        }

        case BOBBA_CHASING: {
            if (!target) {
                bobba->state = BOBBA_ROAMING;
                break;
            }

            // Attack if close enough
            if (dist_to_target <= BOBBA_ATTACK_DISTANCE) {
                bobba->state = BOBBA_ATTACKING;
                bobba->attack_timer = BOBBA_ATTACK_DURATION;
                bobba->attack_start_time = BOBBA_ATTACK_DURATION;  // Record for progress calc
                bobba->has_hit_this_attack = 0;  // Reset hit flag for new attack
                break;
            }

            // Move toward target
            float dx = target->data.pos_x - bobba->pos_x;
            float dz = target->data.pos_z - bobba->pos_z;
            float len = sqrt(dx*dx + dz*dz);
            if (len > 0.1f) {
                dx /= len;
                dz /= len;
                bobba->pos_x += dx * BOBBA_CHASE_SPEED * delta;
                bobba->pos_z += dz * BOBBA_CHASE_SPEED * delta;
                bobba->rot_y = atan2(dx, dz);
            }
            break;
        }

        case BOBBA_ATTACKING:
            // Handled above
            break;

        case BOBBA_IDLE:
            // Do nothing, wait for player
            break;

        case BOBBA_STUNNED:
            // Handled above
            break;
    }
}

// Update all Bobbas
void update_all_bobbas(float delta) {

    for (int i = 0; i < MAX_BOBBAS; i++) {
        if (bobbas[i].active) {
            update_bobba_ai(&bobbas[i], delta);
        }
    }

}

// Respawn all Bobbas (reset health, position, state)
void respawn_all_bobbas() {

    for (int i = 0; i < MAX_BOBBAS; i++) {
        // Only respawn Bobbas that were actually spawned (have valid entity_id)
        if (bobbas[i].entity_id == 0) {
            continue;  // Skip slots that were never used
        }

        // Respawn at original position
        bobbas[i].pos_x = 5.0f;
        bobbas[i].pos_y = 0.0f;
        bobbas[i].pos_z = 5.0f;
        bobbas[i].rot_y = 0;
        bobbas[i].state = BOBBA_ROAMING;
        bobbas[i].health = 100.0f;
        bobbas[i].active = 1;
        bobbas[i].target_player_id = 0;
        bobbas[i].has_hit_this_attack = 0;
        bobbas[i].stun_timer = 0;
        bobbas[i].attack_timer = 0;

        // Random roam direction
        float angle = ((float)rand() / RAND_MAX) * 2.0f * M_PI;
        bobbas[i].roam_dir_x = cos(angle);
        bobbas[i].roam_dir_z = sin(angle);
        bobbas[i].roam_timer = BOBBA_ROAM_CHANGE_TIME;

        printf("Respawned Bobba %u at (%.1f, %.1f, %.1f)\n",
               bobbas[i].entity_id, bobbas[i].pos_x, bobbas[i].pos_y, bobbas[i].pos_z);
    }

}

// Reset all players' health and respawn positions
void respawn_all_players() {

    for (int i = 0; i < MAX_PLAYERS; i++) {
        if (players[i].active) {
            // Reset health
            players[i].data.health = 100.0f;
            players[i].data.state = STATE_IDLE;

            // Generate new spawn position
            generate_spawn_position(&players[i].data.pos_x,
                                    &players[i].data.pos_y,
                                    &players[i].data.pos_z);

            printf("Respawned player %u at (%.1f, %.1f, %.1f)\n",
                   players[i].player_id,
                   players[i].data.pos_x, players[i].data.pos_y, players[i].data.pos_z);
        }
    }

}

// Handle game restart request - broadcast to all players and respawn entities
void handle_game_restart(uint32_t reason, uint32_t requester_id) {
    printf("=== GAME RESTART ===\n");
    printf("Requested by player %u (reason: %u)\n", requester_id, reason);
    fflush(stdout);

    // Respawn all entities
    respawn_all_bobbas();
    respawn_all_players();

    // Build restart packet to broadcast
    GameRestartPacket packet;
    memset(&packet, 0, sizeof(packet));
    packet.header.type = PKT_GAME_RESTART;
    packet.header.sequence = ++state_sequence;
    packet.header.player_id = 0;  // From server
    packet.reason = reason;

    // Broadcast to all players
    int player_count = 0;
    for (int i = 0; i < MAX_PLAYERS; i++) {
        if (players[i].active) {
            sendto(server_socket, &packet, sizeof(packet), 0,
                   (struct sockaddr*)&players[i].addr, sizeof(players[i].addr));
            player_count++;
        }
    }

    printf("Game restart broadcast sent to %d players\n", player_count);

    // Immediately broadcast updated entity state so clients see respawned entities
    broadcast_entity_state();
    broadcast_world_state();

    printf("=== RESTART COMPLETE ===\n");
    fflush(stdout);
}

// Broadcast entity state to all players
void broadcast_entity_state() {

    int entity_count = 0;
    for (int i = 0; i < MAX_BOBBAS; i++) {
        if (bobbas[i].active) entity_count++;
    }
    for (int i = 0; i < MAX_DRAGONS; i++) {
        if (dragons[i].active) entity_count++;
    }

    if (entity_count == 0) {
            return;
    }

    // Build entity state packet
    EntityStatePacket packet;
    memset(&packet, 0, sizeof(packet));
    packet.header.type = PKT_ENTITY_STATE;
    packet.header.sequence = ++state_sequence;
    packet.header.player_id = 0;  // From server

    int idx = 0;

    // Add Bobbas
    for (int i = 0; i < MAX_BOBBAS && idx < MAX_ENTITIES; i++) {
        if (bobbas[i].active) {
            packet.entities[idx].entity_type = ENTITY_BOBBA;
            packet.entities[idx].entity_id = bobbas[i].entity_id;
            packet.entities[idx].pos_x = bobbas[i].pos_x;
            packet.entities[idx].pos_y = bobbas[i].pos_y;
            packet.entities[idx].pos_z = bobbas[i].pos_z;
            packet.entities[idx].rot_y = bobbas[i].rot_y;
            packet.entities[idx].state = bobbas[i].state;
            packet.entities[idx].health = bobbas[i].health;
            idx++;
        }
    }

    // Add Dragons
    for (int i = 0; i < MAX_DRAGONS && idx < MAX_ENTITIES; i++) {
        if (dragons[i].active) {
            packet.entities[idx].entity_type = ENTITY_DRAGON;
            packet.entities[idx].entity_id = dragons[i].entity_id;
            packet.entities[idx].pos_x = dragons[i].pos_x;
            packet.entities[idx].pos_y = dragons[i].pos_y;
            packet.entities[idx].pos_z = dragons[i].pos_z;
            packet.entities[idx].rot_y = dragons[i].rot_y;
            packet.entities[idx].state = dragons[i].state;
            packet.entities[idx].health = dragons[i].health;
            // Extra data for dragon: lap_count and patrol_angle
            packet.entities[idx].extra1 = dragons[i].laps_completed;
            packet.entities[idx].extra2 = dragons[i].patrol_angle;
            idx++;
        }
    }

    packet.entity_count = idx;

    // Send to all active players
    for (int i = 0; i < MAX_PLAYERS; i++) {
        if (players[i].active) {
            sendto(server_socket, &packet, sizeof(PacketHeader) + 1 + idx * sizeof(EntityData), 0,
                   (struct sockaddr*)&players[i].addr, sizeof(players[i].addr));
        }
    }

    // Also send to all spectators (so they can see entities before joining)
    for (int i = 0; i < MAX_SPECTATORS; i++) {
        if (spectators[i].active) {
            sendto(server_socket, &packet, sizeof(PacketHeader) + 1 + idx * sizeof(EntityData), 0,
                   (struct sockaddr*)&spectators[i].addr, sizeof(spectators[i].addr));
        }
    }

}

// Send damage to a specific player (called when entity attacks player)
void send_player_damage(uint32_t target_player_id, float damage, uint32_t attacker_entity_id,
                        float knockback_x, float knockback_y, float knockback_z) {

    Player *target = find_player_by_id(target_player_id);
    if (target && target->active) {
        PlayerDamagePacket packet;
        memset(&packet, 0, sizeof(packet));
        packet.header.type = PKT_PLAYER_DAMAGE;
        packet.header.sequence = ++state_sequence;
        packet.header.player_id = 0;  // From server
        packet.target_player_id = target_player_id;
        packet.damage = damage;
        packet.attacker_entity_id = attacker_entity_id;
        packet.knockback_x = knockback_x;
        packet.knockback_y = knockback_y;
        packet.knockback_z = knockback_z;

        sendto(server_socket, &packet, sizeof(packet), 0,
               (struct sockaddr*)&target->addr, sizeof(target->addr));

        printf("Sent player damage: player %u takes %.1f damage from entity %u\n",
               target_player_id, damage, attacker_entity_id);
        fflush(stdout);
    }

}

// Handle entity damage from a player
void handle_entity_damage_server(uint32_t entity_id, float damage, uint32_t attacker_id) {
    printf(">>> ENTITY DAMAGE: entity=%u damage=%.1f attacker=%u\n", entity_id, damage, attacker_id);
    fflush(stdout);

    for (int i = 0; i < MAX_BOBBAS; i++) {
        if (bobbas[i].active && bobbas[i].entity_id == entity_id) {
            bobbas[i].health -= damage;
            bobbas[i].stun_timer = 0.5f;
            bobbas[i].state = BOBBA_STUNNED;

            // Switch target to attacker
            bobbas[i].target_player_id = attacker_id;

            printf("Bobba %u took %.1f damage from player %u (health: %.1f)\n",
                   entity_id, damage, attacker_id, bobbas[i].health);
            fflush(stdout);

            if (bobbas[i].health <= 0) {
                printf("Bobba %u died! Broadcasting restart to all players.\n", entity_id);
                fflush(stdout);
                bobbas[i].active = 0;
                // Server broadcasts restart - don't wait for client request
                handle_game_restart(1, 0);  // reason=1 (Bobba died), requester=0 (server)
            }
            return;
        }
    }
    printf(">>> Entity %u not found in Bobbas\n", entity_id);
    fflush(stdout);

    // Also check dragons
    for (int i = 0; i < MAX_DRAGONS; i++) {
        if (dragons[i].active && dragons[i].entity_id == entity_id) {
            dragons[i].health -= damage;
            printf("Dragon %u took %.1f damage from player %u (health: %.1f)\n",
                   entity_id, damage, attacker_id, dragons[i].health);
            fflush(stdout);

            if (dragons[i].health <= 0) {
                printf("Dragon %u died!\n", entity_id);
                dragons[i].active = 0;
            }
            break;
        }
    }

}

// =============================================================================
// DRAGON AI (Server-authoritative)
// =============================================================================

// Initialize a Dragon
void spawn_dragon(float center_x, float center_z) {

    for (int i = 0; i < MAX_DRAGONS; i++) {
        if (!dragons[i].active) {
            memset(&dragons[i], 0, sizeof(ServerDragon));
            dragons[i].entity_id = next_entity_id++;
            dragons[i].patrol_center_x = center_x;
            dragons[i].patrol_center_z = center_z;
            dragons[i].patrol_angle = 0.0f;

            // Start at patrol position
            dragons[i].pos_x = center_x + DRAGON_PATROL_RADIUS;
            dragons[i].pos_y = DRAGON_PATROL_HEIGHT;
            dragons[i].pos_z = center_z;
            dragons[i].rot_y = 0;
            dragons[i].state = DRAGON_PATROL;
            dragons[i].health = 500.0f;
            dragons[i].active = 1;
            dragons[i].laps_completed = 0;

            printf("Spawned Dragon %u at (%.1f, %.1f, %.1f), patrol center (%.1f, %.1f)\n",
                   dragons[i].entity_id, dragons[i].pos_x, dragons[i].pos_y, dragons[i].pos_z,
                   center_x, center_z);
            fflush(stdout);
            break;
        }
    }

}

// Get dragon patrol position based on angle
void get_dragon_patrol_position(ServerDragon *dragon, float *out_x, float *out_y, float *out_z) {
    // Oval patrol path with slight height variation
    *out_x = dragon->patrol_center_x + cos(dragon->patrol_angle) * DRAGON_PATROL_RADIUS;
    *out_z = dragon->patrol_center_z + sin(dragon->patrol_angle) * DRAGON_PATROL_RADIUS * 0.7f;  // Oval
    *out_y = DRAGON_PATROL_HEIGHT + sin(dragon->patrol_angle * 2) * 5.0f;  // Gentle undulation
}

// Update a single Dragon's AI
void update_dragon_ai(ServerDragon *dragon, float delta) {
    if (!dragon->active) return;

    // TEST_MULTIPLAYER mode: skip AI, just patrol (no attacks)
    if (test_multiplayer) {
        dragon->state = DRAGON_PATROL;
        // Still update patrol position for visual interest
        dragon->patrol_angle += DRAGON_PATROL_SPEED * delta / DRAGON_PATROL_RADIUS;
        if (dragon->patrol_angle > 2.0f * M_PI) {
            dragon->patrol_angle -= 2.0f * M_PI;
        }
        float target_x, target_y, target_z;
        get_dragon_patrol_position(dragon, &target_x, &target_y, &target_z);
        dragon->pos_x = target_x;
        dragon->pos_y = target_y;
        dragon->pos_z = target_z;
        return;
    }

    switch (dragon->state) {
        case DRAGON_PATROL: {
            // Move along circular patrol path
            dragon->patrol_angle += (DRAGON_PATROL_SPEED / DRAGON_PATROL_RADIUS) * delta;

            // Check for lap completion
            if (dragon->patrol_angle >= 2.0f * M_PI) {
                dragon->patrol_angle -= 2.0f * M_PI;
                dragon->laps_completed++;
                printf("Dragon %u completed lap %d\n", dragon->entity_id, dragon->laps_completed);

                // Land after specified laps
                if (dragon->laps_completed >= DRAGON_LAPS_BEFORE_LANDING) {
                    dragon->laps_completed = 0;
                    dragon->state = DRAGON_FLYING_TO_LAND;
                    printf("Dragon %u flying to landing spot\n", dragon->entity_id);
                }
            }

            // Move towards patrol position
            float target_x, target_y, target_z;
            get_dragon_patrol_position(dragon, &target_x, &target_y, &target_z);

            float dx = target_x - dragon->pos_x;
            float dy = target_y - dragon->pos_y;
            float dz = target_z - dragon->pos_z;
            float len = sqrt(dx*dx + dy*dy + dz*dz);

            if (len > 0.1f) {
                dx /= len; dy /= len; dz /= len;
                dragon->pos_x += dx * DRAGON_PATROL_SPEED * delta;
                dragon->pos_y += dy * DRAGON_PATROL_SPEED * delta;
                dragon->pos_z += dz * DRAGON_PATROL_SPEED * delta;
                dragon->rot_y = atan2(dx, dz);
            }
            break;
        }

        case DRAGON_FLYING_TO_LAND: {
            // Fly towards landing spot (approach from above)
            float approach_x = DRAGON_LANDING_SPOT_X;
            float approach_y = DRAGON_LANDING_SPOT_Y + 20.0f;  // Approach from above
            float approach_z = DRAGON_LANDING_SPOT_Z;

            float dx = approach_x - dragon->pos_x;
            float dy = approach_y - dragon->pos_y;
            float dz = approach_z - dragon->pos_z;
            float dist = sqrt(dx*dx + dy*dy + dz*dz);

            if (dist > 0.1f) {
                dx /= dist; dy /= dist; dz /= dist;
                dragon->pos_x += dx * DRAGON_PATROL_SPEED * delta;
                dragon->pos_y += dy * DRAGON_PATROL_SPEED * delta;
                dragon->pos_z += dz * DRAGON_PATROL_SPEED * delta;
                dragon->rot_y = atan2(dx, dz);
            }

            // Start landing descent when close
            if (dist < 10.0f) {
                dragon->state = DRAGON_LANDING;
                printf("Dragon %u starting landing descent\n", dragon->entity_id);
            }
            break;
        }

        case DRAGON_LANDING: {
            // Descend towards landing spot
            float dx = DRAGON_LANDING_SPOT_X - dragon->pos_x;
            float dy = DRAGON_LANDING_SPOT_Y - dragon->pos_y;
            float dz = DRAGON_LANDING_SPOT_Z - dragon->pos_z;
            float dist = sqrt(dx*dx + dy*dy + dz*dz);

            // Slow down as we approach
            float speed = fminf(dist * 0.5f, DRAGON_PATROL_SPEED);
            speed = fmaxf(speed, 2.0f);

            if (dist > 0.1f) {
                dx /= dist; dy /= dist; dz /= dist;
                dragon->pos_x += dx * speed * delta;
                dragon->pos_y += dy * speed * delta;
                dragon->pos_z += dz * speed * delta;
            }

            // Check if landed
            if (dist < 5.0f) {
                dragon->pos_x = DRAGON_LANDING_SPOT_X;
                dragon->pos_y = DRAGON_LANDING_SPOT_Y;
                dragon->pos_z = DRAGON_LANDING_SPOT_Z;
                dragon->state = DRAGON_WAIT;
                dragon->wait_timer = 0.0f;
                printf("Dragon %u landed! Waiting for %.1f seconds\n",
                       dragon->entity_id, DRAGON_WAIT_TIME);
            }
            break;
        }

        case DRAGON_WAIT: {
            dragon->wait_timer += delta;

            // Check for nearby player to attack
            float nearest_dist = 999999.0f;
            Player *nearest = find_nearest_player(dragon->pos_x, dragon->pos_y, dragon->pos_z, &nearest_dist);

            if (nearest && nearest_dist < DRAGON_ATTACK_RANGE) {
                dragon->state = DRAGON_ATTACKING;
                dragon->attack_timer = 2.0f;  // Attack duration
                dragon->target_player_id = nearest->player_id;
                printf("Dragon %u attacking player %u!\n", dragon->entity_id, nearest->player_id);
                break;
            }

            // Check if wait time complete
            if (dragon->wait_timer >= DRAGON_WAIT_TIME) {
                dragon->state = DRAGON_TAKING_OFF;
                printf("Dragon %u taking off!\n", dragon->entity_id);
            }
            break;
        }

        case DRAGON_ATTACKING: {
            dragon->attack_timer -= delta;

            if (dragon->attack_timer <= 0) {
                // Check if player still in range
                float dist = 999999.0f;
                Player *target = find_player_by_id(dragon->target_player_id);
                if (target && target->active) {
                    dist = distance_3d(dragon->pos_x, dragon->pos_y, dragon->pos_z,
                                       target->data.pos_x, target->data.pos_y, target->data.pos_z);
                }

                if (dist < DRAGON_ATTACK_RANGE) {
                    // Attack again
                    dragon->attack_timer = 2.0f;
                } else {
                    // Return to wait state
                    dragon->state = DRAGON_WAIT;
                    dragon->wait_timer = 0.0f;
                }
            }
            break;
        }

        case DRAGON_TAKING_OFF: {
            // Rise up
            dragon->pos_y += 15.0f * delta;

            // Check if high enough to resume patrol
            if (dragon->pos_y >= DRAGON_PATROL_HEIGHT * 0.8f) {
                dragon->state = DRAGON_PATROL;
                dragon->patrol_angle = 0.0f;  // Reset patrol angle
                printf("Dragon %u resuming patrol\n", dragon->entity_id);
            }
            break;
        }
    }
}

// Update all Dragons
void update_all_dragons(float delta) {
    // Note: entities_mutex and players_mutex should already be held
    for (int i = 0; i < MAX_DRAGONS; i++) {
        if (dragons[i].active) {
            update_dragon_ai(&dragons[i], delta);
        }
    }
}

// Broadcast world state to all players
void broadcast_world_state() {
    WorldStatePacket packet;
    memset(&packet, 0, sizeof(packet));

    packet.header.type = PKT_WORLD_STATE;
    packet.header.sequence = ++state_sequence;
    packet.header.player_id = 0;  // From server
    packet.state_seq = state_sequence;


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

}

// Handle join request
void handle_join(JoinPacket *pkt, struct sockaddr_in *client_addr) {

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
            return;
    }

    // Find free slot
    int slot = find_free_slot();
    if (slot < 0) {
        printf("Server full, rejecting player %s\n", pkt->player_name);
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
    broadcast_world_state();
}

// Handle player update
void handle_update(UpdatePacket *pkt, struct sockaddr_in *client_addr) {

    Player *player = find_player_by_id(pkt->header.player_id);
    if (!player) {
            return;
    }

    // Verify address matches
    if (player->addr.sin_addr.s_addr != client_addr->sin_addr.s_addr ||
        player->addr.sin_port != client_addr->sin_port) {
            return;
    }

    // Update player data
    player->data = pkt->data;
    player->data.player_id = player->player_id;  // Ensure ID is preserved
    player->last_seen = time(NULL);

}

// Handle spectate request
void handle_spectate(PacketHeader *hdr, struct sockaddr_in *client_addr) {

    // Check if already a spectator
    for (int i = 0; i < MAX_SPECTATORS; i++) {
        if (spectators[i].active &&
            spectators[i].addr.sin_addr.s_addr == client_addr->sin_addr.s_addr &&
            spectators[i].addr.sin_port == client_addr->sin_port) {
            spectators[i].last_seen = time(NULL);
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

}

// Handle player leave
void handle_leave(PacketHeader *hdr, struct sockaddr_in *client_addr) {
    (void)client_addr;  // Unused parameter

    Player *player = find_player_by_id(hdr->player_id);
    if (player) {
        printf("Player %s left (ID: %u)\n", player->name, player->player_id);
        player->active = 0;
    }

    broadcast_world_state();
}

// Cleanup timed out players
void cleanup_inactive_players() {
    time_t now = time(NULL);


    for (int i = 0; i < MAX_PLAYERS; i++) {
        if (players[i].active && (now - players[i].last_seen) > PLAYER_TIMEOUT_SEC) {
            printf("Player %s timed out (ID: %u)\n", players[i].name, players[i].player_id);
            players[i].active = 0;
        }
    }

}

// Relay entity state from host to all other clients
void relay_entity_state(void *packet, size_t len, struct sockaddr_in *sender_addr) {

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

}

// Relay arrow spawn to all clients except sender
void relay_arrow_spawn(ArrowSpawnPacket *pkt, size_t len, struct sockaddr_in *sender_addr) {

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

}

// Relay arrow hit to all clients except sender
void relay_arrow_hit(ArrowHitPacket *pkt, size_t len, struct sockaddr_in *sender_addr) {

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

}

// Relay entity damage to host (first/lowest ID player)
void relay_entity_damage(EntityDamagePacket *pkt, size_t len, struct sockaddr_in *sender_addr) {

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

}

int main(int argc, char *argv[]) {
    int port = DEFAULT_PORT;

    // Parse command line arguments
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--test-multiplayer") == 0) {
            test_multiplayer = 1;
            printf("TEST_MULTIPLAYER mode enabled - enemy AI disabled\n");
        } else if (argv[i][0] != '-') {
            port = atoi(argv[i]);
        }
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

    // Initialize players and entities arrays
    memset(players, 0, sizeof(players));
    memset(bobbas, 0, sizeof(bobbas));
    memset(dragons, 0, sizeof(dragons));

    printf("===========================================\n");
    printf("  Douglass The Keeper - Game Server\n");
    printf("===========================================\n");
    printf("Listening on UDP port %d\n", port);
    printf("Max players: %d\n", MAX_PLAYERS);
    printf("Broadcast interval: %d ms\n", BROADCAST_INTERVAL_MS);
    printf("Entity update interval: %d ms\n", ENTITY_UPDATE_INTERVAL_MS);
    printf("Player timeout: %d seconds\n", PLAYER_TIMEOUT_SEC);
    printf("Press Ctrl+C to stop\n");
    printf("===========================================\n\n");
    fflush(stdout);

    // Spawn initial entities
    spawn_bobba(5.0f, 0.0f, 5.0f);    // Bobba near spawn point
    spawn_dragon(0.0f, 10.0f);        // Dragon patrolling around center

    // Set socket to non-blocking for single-threaded event loop
    int flags = fcntl(server_socket, F_GETFL, 0);
    fcntl(server_socket, F_SETFL, flags | O_NONBLOCK);

    // Timing for periodic updates
    struct timespec last_broadcast, last_entity_update, last_cleanup, now;
    clock_gettime(CLOCK_MONOTONIC, &last_broadcast);
    last_entity_update = last_broadcast;
    last_cleanup = last_broadcast;

    char buffer[BUFFER_SIZE];
    struct sockaddr_in client_addr;
    socklen_t addr_len;

    // Single-threaded main loop
    printf("Starting single-threaded event loop...\n");
    fflush(stdout);

    while (running) {
        clock_gettime(CLOCK_MONOTONIC, &now);

        // Calculate elapsed times in milliseconds
        long broadcast_elapsed = (now.tv_sec - last_broadcast.tv_sec) * 1000 +
                                 (now.tv_nsec - last_broadcast.tv_nsec) / 1000000;
        long entity_elapsed = (now.tv_sec - last_entity_update.tv_sec) * 1000 +
                              (now.tv_nsec - last_entity_update.tv_nsec) / 1000000;
        long cleanup_elapsed = (now.tv_sec - last_cleanup.tv_sec) * 1000 +
                               (now.tv_nsec - last_cleanup.tv_nsec) / 1000000;

        // Receive packets (non-blocking)
        addr_len = sizeof(client_addr);
        ssize_t recv_len = recvfrom(server_socket, buffer, BUFFER_SIZE, 0,
                                    (struct sockaddr*)&client_addr, &addr_len);

        if (recv_len > 0) {
            // Process received packet
            if (recv_len >= (ssize_t)sizeof(PacketHeader)) {
                PacketHeader *header = (PacketHeader*)buffer;

                switch (header->type) {
                    case PKT_JOIN:
                        if (recv_len >= (ssize_t)sizeof(JoinPacket)) {
                            handle_join((JoinPacket*)buffer, &client_addr);
                        }
                        break;

                    case PKT_UPDATE:
                        if (recv_len >= (ssize_t)sizeof(UpdatePacket)) {
                            handle_update((UpdatePacket*)buffer, &client_addr);
                        }
                        break;

                    case PKT_LEAVE:
                        handle_leave(header, &client_addr);
                        break;

                    case PKT_PING: {
                        // Respond with pong
                        PacketHeader pong;
                        pong.type = PKT_PONG;
                        pong.player_id = header->player_id;
                        pong.sequence = header->sequence;
                        sendto(server_socket, &pong, sizeof(pong), 0,
                               (struct sockaddr*)&client_addr, sizeof(client_addr));
                        break;
                    }

                    case PKT_ENTITY_DAMAGE:
                        if (recv_len >= (ssize_t)sizeof(EntityDamagePacket)) {
                            EntityDamagePacket *dmg = (EntityDamagePacket*)buffer;
                            handle_entity_damage_server(dmg->entity_id, dmg->damage, dmg->attacker_id);
                        }
                        break;

                    case PKT_ARROW_SPAWN:
                        if (recv_len >= (ssize_t)sizeof(ArrowSpawnPacket)) {
                            relay_arrow_spawn((ArrowSpawnPacket*)buffer, recv_len, &client_addr);
                        }
                        break;

                    case PKT_ARROW_HIT:
                        if (recv_len >= (ssize_t)sizeof(ArrowHitPacket)) {
                            relay_arrow_hit((ArrowHitPacket*)buffer, recv_len, &client_addr);
                        }
                        break;

                    case PKT_HEARTBEAT:
                        // Just update last_seen (already done by finding player)
                        break;

                    case PKT_SPECTATE:
                        handle_spectate(header, &client_addr);
                        break;

                    case PKT_GAME_RESTART:
                        if (recv_len >= (ssize_t)sizeof(GameRestartPacket)) {
                            GameRestartPacket *restart = (GameRestartPacket*)buffer;
                            handle_game_restart(restart->reason, header->player_id);
                        }
                        break;

                    default:
                        break;
                }
            }
        }

        // Periodic world state broadcast
        if (broadcast_elapsed >= BROADCAST_INTERVAL_MS) {
            broadcast_world_state();
            last_broadcast = now;
        }

        // Periodic entity AI update
        if (entity_elapsed >= ENTITY_UPDATE_INTERVAL_MS) {
            float delta = entity_elapsed / 1000.0f;
            update_all_bobbas(delta);
            update_all_dragons(delta);
            broadcast_entity_state();
            last_entity_update = now;

            // Debug: print Bobba state every second
            static int debug_counter = 0;
            if (++debug_counter >= 20) {  // 20 * 50ms = 1 second
                debug_counter = 0;
                for (int i = 0; i < MAX_BOBBAS; i++) {
                    if (bobbas[i].active) {
                        const char *state_names[] = {"ROAMING", "CHASING", "ATTACKING", "IDLE", "STUNNED"};
                        printf("Bobba[%u]: state=%s pos=(%.1f,%.1f,%.1f) hp=%.0f target=%u\n",
                               bobbas[i].entity_id,
                               state_names[bobbas[i].state],
                               bobbas[i].pos_x, bobbas[i].pos_y, bobbas[i].pos_z,
                               bobbas[i].health, bobbas[i].target_player_id);
                        fflush(stdout);
                    }
                }
            }
        }

        // Periodic cleanup of inactive players
        if (cleanup_elapsed >= 1000) {  // Every second
            cleanup_inactive_players();
            last_cleanup = now;
        }

        // Small sleep to avoid busy-waiting (1ms)
        usleep(1000);
    }

    close(server_socket);
    printf("Server stopped.\n");
    return 0;
}
