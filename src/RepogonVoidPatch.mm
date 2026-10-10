#import "RepogonVoidPatch.h"
#import "RepogonEngine.h"
#import "RepogonLogger.h"
#import "RepogonMemory.h"

#include <vector>

namespace {

constexpr size_t kGameCurrentRoomOffset = 0x21550;
constexpr size_t kGameChallengeOffset = 0x1CF438;
constexpr size_t kGameDailyChallengeOffset = 0x1CF4C0;

constexpr size_t kRoomDescriptorOffset = 0x8;
constexpr size_t kRoomDescriptorDataOffset = 0x10;
constexpr size_t kRoomConfigTypeOffset = 0x8;

constexpr size_t kRoomGridEntitiesOffset = 0x30;
constexpr size_t kRoomGridEntityCount = 448;

constexpr size_t kRoomEntitiesArrayOffset = 0x19C8;
constexpr size_t kRoomEntitiesCountOffset = 0x19D4;

constexpr uintptr_t kTrapDoorVTableRVA = 0xA8E650;

constexpr uintptr_t kRoomGetCenterPosRVA = 0x59E2AC;
constexpr uintptr_t kRoomGetGridIndexRVA = 0x5A18AC;
constexpr uintptr_t kRoomFindFreeTileRVA = 0x5AB878;
constexpr uintptr_t kGetDefaultDescRVA = 0x7F1CC0;
constexpr uintptr_t kRoomSpawnGridEntityRVA = 0x59ABC4;
constexpr uintptr_t kGameSpawnEntityRVA = 0x88FCBC;
constexpr uintptr_t kGetCutsceneEventRVA = 0x6D4CB8;

typedef Vector2f (*GetCenterPos_t)(void *room);
typedef int32_t (*GetGridIndex_t)(void *room, const Vector2f *pos);
typedef void (*FindFreeTile_t)(void *room, int32_t *gridIndex);
typedef void* (*GetDefaultDesc_t)();
typedef bool (*SpawnGridEntity_t)(void *room, int32_t gridIndex, int32_t type, int32_t varIdx, void *desc, int32_t varData);
typedef void* (*GameSpawn_t)(void *game, int32_t type, int32_t variant, const Vector2f *pos, const Vector2f *velocity, void *spawner, int32_t subType, uint32_t seed);
typedef void* (*GetCutsceneEvent_t)(void *game, int32_t eventId, int32_t subId);

static uintptr_t g_currentRoomAddr = 0;
static bool g_seenMegaSatanPhase2 = false;
static bool g_seenMotherPhase2 = false;
static int32_t g_guaranteedPortalGridIdx = -1;
static uint32_t g_chestDropDelayTicks = 0;
constexpr uint32_t kChestDropDelayTicks = 8;
static bool g_spawnedGuaranteedPortal = false;

static void RemoveNaturalVoidPortals(uintptr_t roomAddr, uintptr_t base, int32_t allowedGridIdx) {
    if (!roomAddr || !base) return;
    uintptr_t trapDoorVTable = base + kTrapDoorVTableRVA;
    uintptr_t gridEntitiesAddr = roomAddr + kRoomGridEntitiesOffset;

    uintptr_t gridEntities[kRoomGridEntityCount] = {0};
    if (!SafeReadBytes(gridEntitiesAddr, gridEntities, sizeof(gridEntities))) return;

    for (size_t i = 0; i < kRoomGridEntityCount; ++i) {
        uintptr_t entPtr = gridEntities[i];
        if (!entPtr) continue;

        uintptr_t vtable = 0;
        if (!SafeRead(entPtr, vtable)) continue;

        if (vtable == trapDoorVTable) {
            int32_t varData = 0;
            if (SafeRead(entPtr + 0x1C, varData) && varData == 1) {
                if (allowedGridIdx < 0 || static_cast<int32_t>(i) != allowedGridIdx) {
                    uintptr_t dtorAddr = 0;
                    if (SafeRead(vtable + 8, dtorAddr) && dtorAddr) {
                        typedef void (*Dtor_t)(void *);
                        Dtor_t dtor = reinterpret_cast<Dtor_t>(dtorAddr);
                        @try { dtor(reinterpret_cast<void *>(entPtr)); } @catch (...) {}
                    }
                    uintptr_t zero = 0;
                    SafeWrite(gridEntitiesAddr + i * sizeof(uintptr_t), zero);
                    RepogonLog(@"[VoidPatch] Removed duplicate portal at tile %zu", i);
                }
            }
        }
    }
}

static bool CheckBossAndChestState(uintptr_t roomAddr, int32_t roomType, int32_t stage, int32_t stageType, bool &outHasChest) {
    if (!roomAddr) return false;

    uintptr_t entitiesArrayPtr = 0;
    int32_t count = 0;
    if (!SafeRead(roomAddr + kRoomEntitiesArrayOffset, entitiesArrayPtr) || !entitiesArrayPtr) return false;
    if (!SafeRead(roomAddr + kRoomEntitiesCountOffset, count) || count <= 0 || count > 2048) return false;

    bool foundEndingChest = false;
    bool hasAliveBoss = false;

    for (int32_t i = 0; i < count; ++i) {
        uintptr_t entity = 0;
        if (!SafeRead(entitiesArrayPtr + i * sizeof(uintptr_t), entity) || !entity) continue;

        int32_t type = 0;
        int32_t variant = 0;
        uint8_t isDead = 0;

        if (!SafeRead(entity + 0x38, type)) continue;
        SafeRead(entity + 0x3C, variant);
        SafeRead(entity + 0x1C3, isDead);

        if (type == 5) {
            if (variant == 340) {
                foundEndingChest = true;
            } else if (variant == 370 && stage == 8 && stageType == 4) {
                foundEndingChest = true;
            }
        }

        if (roomType == 22 && type == 275) {
            g_seenMegaSatanPhase2 = true;
        }

        if (stage == 8 && stageType == 4 && type == 912 && variant >= 10) {
            g_seenMotherPhase2 = true;
        }

        if (type >= 10 && type < 1000 && !isDead) {
            float hp = 0.0f;
            if (SafeRead(entity + 0x354, hp) && hp > 0.0f) {
                hasAliveBoss = true;
            }
        }
    }

    outHasChest = foundEndingChest;

    if (roomType == 22) {
        if (!g_seenMegaSatanPhase2) return false;
        if (hasAliveBoss) return false;
        return true;
    }

    if (stage == 8 && stageType == 4) {
        if (!g_seenMotherPhase2 && !foundEndingChest) return false;
        if (hasAliveBoss) return false;
        return true;
    }

    if (foundEndingChest) return true;
    if (!hasAliveBoss) return true;

    return false;
}

static int32_t SpawnVoidPortal(void *room, uintptr_t base) {
    if (!room || !base) return -1;

    GetCenterPos_t GetCenterPos = reinterpret_cast<GetCenterPos_t>(base + kRoomGetCenterPosRVA);
    GetGridIndex_t GetGridIndex = reinterpret_cast<GetGridIndex_t>(base + kRoomGetGridIndexRVA);
    FindFreeTile_t FindFreeTile = reinterpret_cast<FindFreeTile_t>(base + kRoomFindFreeTileRVA);
    GetDefaultDesc_t GetDefaultDesc = reinterpret_cast<GetDefaultDesc_t>(base + kGetDefaultDescRVA);
    SpawnGridEntity_t SpawnGridEntity = reinterpret_cast<SpawnGridEntity_t>(base + kRoomSpawnGridEntityRVA);

    Vector2f pos = GetCenterPos(room);
    pos.y += 80.0f;
    int32_t gridIdx = GetGridIndex(room, &pos);
    FindFreeTile(room, &gridIdx);
    void *desc = GetDefaultDesc();

    bool ok = SpawnGridEntity(room, gridIdx, 17, 0, desc, 1);
    RepogonLog(@"[VoidPatch] Spawned guaranteed Void Portal at tile %d (success: %d)", gridIdx, (int)ok);
    return ok ? gridIdx : -1;
}

static void SpawnBigChest(uintptr_t gameAddr, void *room, uintptr_t base) {
    if (!gameAddr || !room || !base) return;

    GetCenterPos_t GetCenterPos = reinterpret_cast<GetCenterPos_t>(base + kRoomGetCenterPosRVA);
    GameSpawn_t GameSpawn = reinterpret_cast<GameSpawn_t>(base + kGameSpawnEntityRVA);

    Vector2f center = GetCenterPos(room);
    Vector2f zeroVel = {0.0f, 0.0f};

    void *chest = GameSpawn(reinterpret_cast<void *>(gameAddr), 5, 340, &center, &zeroVel, nullptr, 0, 1);
    RepogonLog(@"[VoidPatch] Spawned Big Chest (5.340) in Mega Satan room (ptr: 0x%lx)", (unsigned long)chest);
}

static void SuppressMegaSatanCutscene(uintptr_t gameAddr, uintptr_t base) {
    if (!gameAddr || !base) return;
    GetCutsceneEvent_t GetCutsceneEvent = reinterpret_cast<GetCutsceneEvent_t>(base + kGetCutsceneEventRVA);
    void *event = GetCutsceneEvent(reinterpret_cast<void *>(gameAddr), -11, -1);
    if (event) {
        uintptr_t activeCutscene = 0;
        SafeRead(reinterpret_cast<uintptr_t>(event) + 0x10, activeCutscene);
        if (!activeCutscene) {
            uintptr_t sentinel = 1;
            SafeWrite(reinterpret_cast<uintptr_t>(event) + 0x10, sentinel);
            RepogonLog(@"[VoidPatch] Suppressed automatic Mega Satan Ending 16 cutscene.");
        }
    }
}

static void CheckAndSpawnVoidPortal(uintptr_t gameAddr, uintptr_t roomAddr, uintptr_t base) {
    if (!gameAddr || !roomAddr || !base) return;

    if (roomAddr != g_currentRoomAddr) {
        g_currentRoomAddr = roomAddr;
        g_seenMegaSatanPhase2 = false;
        g_seenMotherPhase2 = false;
        g_guaranteedPortalGridIdx = -1;
        g_chestDropDelayTicks = 0;
        g_spawnedGuaranteedPortal = false;
    }

    int32_t stage = 0;
    int32_t stageType = 0;
    if (!SafeRead(gameAddr + 0x0, stage)) return;
    if (!SafeRead(gameAddr + 0x4, stageType)) return;

    bool eligibleStage = false;
    if (stage == 8 && stageType == 4) {
        eligibleStage = true;
    } else if (stage == 10 || stage == 11) {
        eligibleStage = true;
    }
    if (!eligibleStage) return;

    int32_t roomType = 0;
    uintptr_t descriptor = 0;
    if (SafeRead(roomAddr + kRoomDescriptorOffset, descriptor) && descriptor) {
        uintptr_t roomData = 0;
        if (SafeRead(descriptor + kRoomDescriptorDataOffset, roomData) && roomData) {
            SafeRead(roomData + kRoomConfigTypeOffset, roomType);
        }
    }

    if (stage == 8 && roomType != 5) return;
    if ((stage == 10 || stage == 11) && roomType != 5 && roomType != 22) return;

    int32_t challengeId = 0;
    if (SafeRead(gameAddr + kGameChallengeOffset, challengeId) && challengeId != 0) {
        RemoveNaturalVoidPortals(roomAddr, base, -1);
        return;
    }

    int32_t dailyChallenge = 0;
    if (SafeRead(gameAddr + kGameDailyChallengeOffset, dailyChallenge) && dailyChallenge != 0) {
        RemoveNaturalVoidPortals(roomAddr, base, -1);
        return;
    }

    bool hasChest = false;
    bool bossDefeated = CheckBossAndChestState(roomAddr, roomType, stage, stageType, hasChest);
    if (!bossDefeated) {
        RemoveNaturalVoidPortals(roomAddr, base, g_guaranteedPortalGridIdx);
        return;
    }

    if (roomType == 22) {
        SuppressMegaSatanCutscene(gameAddr, base);
        if (!hasChest) {
            SpawnBigChest(gameAddr, reinterpret_cast<void *>(roomAddr), base);
            hasChest = true;
        }
    }

    if (g_spawnedGuaranteedPortal) {
        RemoveNaturalVoidPortals(roomAddr, base, g_guaranteedPortalGridIdx);
        return;
    }

    RemoveNaturalVoidPortals(roomAddr, base, -1);

    if (hasChest) {
        if (++g_chestDropDelayTicks < kChestDropDelayTicks) {
            return;
        }
    }

    GetCenterPos_t GetCenterPos = reinterpret_cast<GetCenterPos_t>(base + kRoomGetCenterPosRVA);
    GetGridIndex_t GetGridIndex = reinterpret_cast<GetGridIndex_t>(base + kRoomGetGridIndexRVA);
    FindFreeTile_t FindFreeTile = reinterpret_cast<FindFreeTile_t>(base + kRoomFindFreeTileRVA);

    Vector2f pos = GetCenterPos(reinterpret_cast<void *>(roomAddr));
    pos.y += 80.0f;
    int32_t targetGridIdx = GetGridIndex(reinterpret_cast<void *>(roomAddr), &pos);
    FindFreeTile(reinterpret_cast<void *>(roomAddr), &targetGridIdx);

    int32_t spawnedIdx = SpawnVoidPortal(reinterpret_cast<void *>(roomAddr), base);
    g_guaranteedPortalGridIdx = (spawnedIdx >= 0) ? spawnedIdx : targetGridIdx;
    g_spawnedGuaranteedPortal = true;

    RemoveNaturalVoidPortals(roomAddr, base, g_guaranteedPortalGridIdx);
}

} // namespace

void RepogonVoidWatchdogTick(void) {
    uintptr_t base = RepogonGetBaseAddress();
    if (!base) return;

    uintptr_t game = RepogonGetGame();
    if (!game) return;

    uintptr_t room = RepogonGetRoom();
    if (!room) return;

    CheckAndSpawnVoidPortal(game, room, base);
}
