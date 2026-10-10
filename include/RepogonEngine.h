#pragma once

#import <Foundation/Foundation.h>
#include <cstdint>
#include <vector>

struct Vector2f {
    float x;
    float y;
};

#ifdef __cplusplus
extern "C" {
#endif

uintptr_t RepogonGetBaseAddress(void);
bool RepogonIsSupportedBuild(uintptr_t *outBase);

uintptr_t RepogonGetGame(void);
uintptr_t RepogonGetRoom(void);
uintptr_t RepogonGetPlayer(int index);
size_t RepogonGetEntityCount(void);
uintptr_t RepogonGetEntityAtIndex(size_t index);
std::vector<uintptr_t> RepogonFindEntities(int type, int variant, int subType);

// Entity Properties
int32_t RepogonEntityGetType(uintptr_t ent);
int32_t RepogonEntityGetVariant(uintptr_t ent);
int32_t RepogonEntityGetSubType(uintptr_t ent);
Vector2f RepogonEntityGetPosition(uintptr_t ent);
void RepogonEntitySetPosition(uintptr_t ent, Vector2f pos);
Vector2f RepogonEntityGetVelocity(uintptr_t ent);
void RepogonEntitySetVelocity(uintptr_t ent, Vector2f vel);
float RepogonEntityGetHP(uintptr_t ent);
void RepogonEntitySetHP(uintptr_t ent, float hp);
float RepogonEntityGetMaxHP(uintptr_t ent);
void RepogonEntitySetMaxHP(uintptr_t ent, float maxHp);
uint64_t RepogonEntityGetFlags(uintptr_t ent);
void RepogonEntitySetFlags(uintptr_t ent, uint64_t flags);
bool RepogonEntityIsDead(uintptr_t ent);
void RepogonEntityKill(uintptr_t ent);

// Player Properties
int32_t RepogonPlayerGetHearts(uintptr_t player);
void RepogonPlayerSetHearts(uintptr_t player, int32_t hearts);
int32_t RepogonPlayerGetMaxHearts(uintptr_t player);
void RepogonPlayerSetMaxHearts(uintptr_t player, int32_t hearts);
int32_t RepogonPlayerGetSoulHearts(uintptr_t player);
void RepogonPlayerSetSoulHearts(uintptr_t player, int32_t hearts);
int32_t RepogonPlayerGetBlackHearts(uintptr_t player);
void RepogonPlayerSetBlackHearts(uintptr_t player, int32_t hearts);
int32_t RepogonPlayerGetBoneHearts(uintptr_t player);
void RepogonPlayerSetBoneHearts(uintptr_t player, int32_t hearts);
int32_t RepogonPlayerGetCoins(uintptr_t player);
void RepogonPlayerAddCoins(uintptr_t player, int32_t coins);
int32_t RepogonPlayerGetBombs(uintptr_t player);
void RepogonPlayerAddBombs(uintptr_t player, int32_t bombs);
int32_t RepogonPlayerGetKeys(uintptr_t player);
void RepogonPlayerAddKeys(uintptr_t player, int32_t keys);
float RepogonPlayerGetDamage(uintptr_t player);
void RepogonPlayerSetDamage(uintptr_t player, float dmg);
float RepogonPlayerGetMoveSpeed(uintptr_t player);
void RepogonPlayerSetMoveSpeed(uintptr_t player, float spd);
int32_t RepogonPlayerGetActiveItem(uintptr_t player, int slot);
int32_t RepogonPlayerGetActiveCharge(uintptr_t player, int slot);
void RepogonPlayerSetActiveCharge(uintptr_t player, int charge, int slot);
int32_t RepogonPlayerGetType(uintptr_t player);

// Room Properties
int32_t RepogonRoomGetType(void);
Vector2f RepogonRoomGetCenterPos(void);
int32_t RepogonRoomGetGridIndex(Vector2f pos);
bool RepogonRoomIsClear(void);

// Game actions
uintptr_t RepogonGameSpawn(int type, int variant, Vector2f pos, Vector2f vel, uintptr_t spawner, int subType, uint32_t seed);
int32_t RepogonGameGetStage(void);
int32_t RepogonGameGetStageType(void);
uint32_t RepogonGameGetFrameCount(void);

#ifdef __cplusplus
}
#endif
