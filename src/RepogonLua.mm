#import "RepogonLua.h"
#import "RepogonEngine.h"
#import "RepogonLogger.h"
#import "RepogonOverlay.h"
#import "lua_json.h"

extern "C" {
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
}

#include <vector>
#include <string>
#include <unordered_map>
#include <cmath>
#include <functional>

namespace {

lua_State *g_L = nullptr;

static int LuaInclude(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    std::string p(path);
    if (p.size() >= 4 && p.substr(p.size() - 4) == ".lua") {
        p = p.substr(0, p.size() - 4);
    }
    lua_getglobal(L, "require");
    lua_pushstring(L, p.c_str());
    lua_call(L, 1, 1);
    return 1;
}

struct CallbackEntry {
    std::string modName;
    int funcRef;
    int param; // Optional entity type, item ID, or -1
};

static std::unordered_map<int, std::vector<CallbackEntry>> g_callbacks;
static std::unordered_map<uintptr_t, int> g_entityDataRefs;

// Forward Declarations
void PushEntity(lua_State *L, uintptr_t ent);
void PushPlayer(lua_State *L, uintptr_t player);
void PushRoom(lua_State *L, uintptr_t room);
void PushGame(lua_State *L, uintptr_t game);
void PushLevel(lua_State *L);
void PushVector(lua_State *L, float x, float y);
Vector2f CheckVector(lua_State *L, int index);

#pragma mark - Custom Print & DebugString

static int LuaPrint(lua_State *L) {
    int n = lua_gettop(L);
    std::string out;
    for (int i = 1; i <= n; ++i) {
        if (i > 1) out += "\t";
        if (lua_isstring(L, i)) {
            out += lua_tostring(L, i);
        } else if (lua_isboolean(L, i)) {
            out += lua_toboolean(L, i) ? "true" : "false";
        } else if (lua_isnil(L, i)) {
            out += "nil";
        } else {
            const char *typeName = luaL_typename(L, i);
            out += std::string("[") + typeName + "]";
        }
    }
    RepogonLogRaw(out.c_str());
    return 0;
}

#pragma mark - Vector Class

static int Vector_new(lua_State *L) {
    float x = static_cast<float>(luaL_optnumber(L, 1, 0.0));
    float y = static_cast<float>(luaL_optnumber(L, 2, 0.0));
    PushVector(L, x, y);
    return 1;
}

void PushVector(lua_State *L, float x, float y) {
    lua_newtable(L);
    lua_pushnumber(L, x);
    lua_setfield(L, -2, "X");
    lua_pushnumber(L, y);
    lua_setfield(L, -2, "Y");
    luaL_getmetatable(L, "IsaacVector");
    lua_setmetatable(L, -2);
}

Vector2f CheckVector(lua_State *L, int index) {
    Vector2f v = {0.0f, 0.0f};
    if (lua_istable(L, index)) {
        lua_getfield(L, index, "X");
        if (lua_isnumber(L, -1)) v.x = static_cast<float>(lua_tonumber(L, -1));
        lua_pop(L, 1);
        lua_getfield(L, index, "Y");
        if (lua_isnumber(L, -1)) v.y = static_cast<float>(lua_tonumber(L, -1));
        lua_pop(L, 1);
    }
    return v;
}

static int Vector_add(lua_State *L) {
    Vector2f a = CheckVector(L, 1);
    Vector2f b = CheckVector(L, 2);
    PushVector(L, a.x + b.x, a.y + b.y);
    return 1;
}

static int Vector_sub(lua_State *L) {
    Vector2f a = CheckVector(L, 1);
    Vector2f b = CheckVector(L, 2);
    PushVector(L, a.x - b.x, a.y - b.y);
    return 1;
}

static int Vector_mul(lua_State *L) {
    Vector2f a = CheckVector(L, 1);
    float scalar = static_cast<float>(luaL_checknumber(L, 2));
    PushVector(L, a.x * scalar, a.y * scalar);
    return 1;
}

static int Vector_div(lua_State *L) {
    Vector2f a = CheckVector(L, 1);
    float scalar = static_cast<float>(luaL_checknumber(L, 2));
    if (scalar != 0.0f) {
        PushVector(L, a.x / scalar, a.y / scalar);
    } else {
        PushVector(L, 0.0f, 0.0f);
    }
    return 1;
}

static int Vector_unm(lua_State *L) {
    Vector2f a = CheckVector(L, 1);
    PushVector(L, -a.x, -a.y);
    return 1;
}

static int Vector_Length(lua_State *L) {
    Vector2f a = CheckVector(L, 1);
    lua_pushnumber(L, std::sqrt(a.x * a.x + a.y * a.y));
    return 1;
}

static int Vector_LengthSquared(lua_State *L) {
    Vector2f a = CheckVector(L, 1);
    lua_pushnumber(L, a.x * a.x + a.y * a.y);
    return 1;
}

static int Vector_Normalized(lua_State *L) {
    Vector2f a = CheckVector(L, 1);
    float len = std::sqrt(a.x * a.x + a.y * a.y);
    if (len > 0.0001f) {
        PushVector(L, a.x / len, a.y / len);
    } else {
        PushVector(L, 0.0f, 0.0f);
    }
    return 1;
}

static int Vector_Distance(lua_State *L) {
    Vector2f a = CheckVector(L, 1);
    Vector2f b = CheckVector(L, 2);
    float dx = a.x - b.x;
    float dy = a.y - b.y;
    lua_pushnumber(L, std::sqrt(dx * dx + dy * dy));
    return 1;
}

static int Vector_Dot(lua_State *L) {
    Vector2f a = CheckVector(L, 1);
    Vector2f b = CheckVector(L, 2);
    lua_pushnumber(L, a.x * b.x + a.y * b.y);
    return 1;
}

static int Vector_Rotated(lua_State *L) {
    Vector2f a = CheckVector(L, 1);
    float deg = static_cast<float>(luaL_checknumber(L, 2));
    float rad = deg * (3.14159265358979323846f / 180.0f);
    float c = std::cos(rad);
    float s = std::sin(rad);
    PushVector(L, a.x * c - a.y * s, a.x * s + a.y * c);
    return 1;
}

static int Vector_tostring(lua_State *L) {
    Vector2f a = CheckVector(L, 1);
    char buf[64];
    snprintf(buf, sizeof(buf), "Vector(%f, %f)", a.x, a.y);
    lua_pushstring(L, buf);
    return 1;
}

#pragma mark - KColor Class

static int KColor_new(lua_State *L) {
    float r = static_cast<float>(luaL_optnumber(L, 1, 1.0));
    float g = static_cast<float>(luaL_optnumber(L, 2, 1.0));
    float b = static_cast<float>(luaL_optnumber(L, 3, 1.0));
    float a = static_cast<float>(luaL_optnumber(L, 4, 1.0));
    lua_newtable(L);
    lua_pushnumber(L, r); lua_setfield(L, -2, "Red");
    lua_pushnumber(L, g); lua_setfield(L, -2, "Green");
    lua_pushnumber(L, b); lua_setfield(L, -2, "Blue");
    lua_pushnumber(L, a); lua_setfield(L, -2, "Alpha");
    return 1;
}

#pragma mark - Stubs for Font and Sprite

static int Font_new(lua_State *L) {
    lua_newtable(L);
    // Method stubs
    lua_pushcfunction(L, [](lua_State *st) -> int { return 0; });
    lua_setfield(L, -2, "Load");
    lua_pushcfunction(L, [](lua_State *st) -> int {
        // DrawString(text, x, y, kcolor, boxWidth, center)
        const char *txt = luaL_optstring(st, 2, "");
        float x = static_cast<float>(luaL_optnumber(st, 3, 0));
        float y = static_cast<float>(luaL_optnumber(st, 4, 0));
        RepogonOverlayAddText([NSString stringWithUTF8String:txt], x, y, 1.0f, 1.0f, 1.0f, 1.0f);
        return 0;
    });
    lua_setfield(L, -2, "DrawString");
    lua_pushcfunction(L, [](lua_State *st) -> int {
        const char *txt = luaL_optstring(st, 2, "");
        float sx = static_cast<float>(luaL_optnumber(st, 5, 1.0));
        float sy = static_cast<float>(luaL_optnumber(st, 6, 1.0));
        float x = static_cast<float>(luaL_optnumber(st, 3, 0));
        float y = static_cast<float>(luaL_optnumber(st, 4, 0));
        RepogonOverlayAddScaledText([NSString stringWithUTF8String:txt], x, y, sx, sy, 1.0f, 1.0f, 1.0f, 1.0f);
        return 0;
    });
    lua_setfield(L, -2, "DrawStringScaled");
    lua_pushcfunction(L, [](lua_State *st) -> int {
        const char *txt = luaL_optstring(st, 2, "");
        lua_pushnumber(st, strlen(txt) * 6.0f);
        return 1;
    });
    lua_setfield(L, -2, "GetStringWidth");
    return 1;
}

static int Sprite_new(lua_State *L) {
    lua_newtable(L);
    auto dummyFunc = [](lua_State *st) -> int { return 0; };
    lua_pushcfunction(L, dummyFunc); lua_setfield(L, -2, "Load");
    lua_pushcfunction(L, dummyFunc); lua_setfield(L, -2, "Play");
    lua_pushcfunction(L, dummyFunc); lua_setfield(L, -2, "SetFrame");
    lua_pushcfunction(L, dummyFunc); lua_setfield(L, -2, "SetAnimation");
    lua_pushcfunction(L, dummyFunc); lua_setfield(L, -2, "Update");
    lua_pushcfunction(L, dummyFunc); lua_setfield(L, -2, "Render");
    lua_pushcfunction(L, dummyFunc); lua_setfield(L, -2, "RenderLayer");
    lua_pushcfunction(L, dummyFunc); lua_setfield(L, -2, "ReplaceSpritesheet");
    lua_pushcfunction(L, dummyFunc); lua_setfield(L, -2, "LoadGraphics");
    lua_pushcfunction(L, dummyFunc); lua_setfield(L, -2, "Reset");
    return 1;
}

#pragma mark - Entity Metatable

static uintptr_t CheckEntityPtr(lua_State *L, int index) {
    if (lua_istable(L, index)) {
        lua_getfield(L, index, "__ptr");
        uintptr_t ptr = static_cast<uintptr_t>(lua_tointeger(L, -1));
        lua_pop(L, 1);
        return ptr;
    }
    return 0;
}

static int Entity_index(lua_State *L) {
    uintptr_t ent = CheckEntityPtr(L, 1);
    const char *key = luaL_checkstring(L, 2);

    if (!ent) return 0;

    if (strcmp(key, "Type") == 0) {
        lua_pushinteger(L, RepogonEntityGetType(ent)); return 1;
    } else if (strcmp(key, "Variant") == 0) {
        lua_pushinteger(L, RepogonEntityGetVariant(ent)); return 1;
    } else if (strcmp(key, "SubType") == 0) {
        lua_pushinteger(L, RepogonEntityGetSubType(ent)); return 1;
    } else if (strcmp(key, "Position") == 0) {
        Vector2f pos = RepogonEntityGetPosition(ent);
        PushVector(L, pos.x, pos.y); return 1;
    } else if (strcmp(key, "Velocity") == 0) {
        Vector2f vel = RepogonEntityGetVelocity(ent);
        PushVector(L, vel.x, vel.y); return 1;
    } else if (strcmp(key, "HitPoints") == 0) {
        lua_pushnumber(L, RepogonEntityGetHP(ent)); return 1;
    } else if (strcmp(key, "MaxHitPoints") == 0) {
        lua_pushnumber(L, RepogonEntityGetMaxHP(ent)); return 1;
    } else if (strcmp(key, "FrameCount") == 0) {
        lua_pushinteger(L, 0); return 1;
    } else if (strcmp(key, "Index") == 0) {
        lua_pushinteger(L, 0); return 1;
    }

    // Check entity metatable methods
    luaL_getmetatable(L, "IsaacEntity");
    lua_pushvalue(L, 2);
    lua_rawget(L, -2);
    return 1;
}

static int Entity_newindex(lua_State *L) {
    uintptr_t ent = CheckEntityPtr(L, 1);
    const char *key = luaL_checkstring(L, 2);
    if (!ent) return 0;

    if (strcmp(key, "Position") == 0) {
        Vector2f pos = CheckVector(L, 3);
        RepogonEntitySetPosition(ent, pos);
    } else if (strcmp(key, "Velocity") == 0) {
        Vector2f vel = CheckVector(L, 3);
        RepogonEntitySetVelocity(ent, vel);
    } else if (strcmp(key, "HitPoints") == 0) {
        float hp = static_cast<float>(luaL_checknumber(L, 3));
        RepogonEntitySetHP(ent, hp);
    } else if (strcmp(key, "MaxHitPoints") == 0) {
        float hp = static_cast<float>(luaL_checknumber(L, 3));
        RepogonEntitySetMaxHP(ent, hp);
    }
    return 0;
}

static int Entity_GetData(lua_State *L) {
    uintptr_t ent = CheckEntityPtr(L, 1);
    if (!ent) { lua_newtable(L); return 1; }

    auto it = g_entityDataRefs.find(ent);
    if (it != g_entityDataRefs.end()) {
        lua_rawgeti(L, LUA_REGISTRYINDEX, it->second);
    } else {
        lua_newtable(L);
        lua_pushvalue(L, -1);
        int ref = luaL_ref(L, LUA_REGISTRYINDEX);
        g_entityDataRefs[ent] = ref;
    }
    return 1;
}

static int Entity_ToPlayer(lua_State *L) {
    uintptr_t ent = CheckEntityPtr(L, 1);
    if (ent && RepogonEntityGetType(ent) == 1) {
        PushPlayer(L, ent);
    } else {
        lua_pushnil(L);
    }
    return 1;
}

static int Entity_Kill(lua_State *L) {
    uintptr_t ent = CheckEntityPtr(L, 1);
    if (ent) RepogonEntityKill(ent);
    return 0;
}

static int Entity_Remove(lua_State *L) {
    uintptr_t ent = CheckEntityPtr(L, 1);
    if (ent) RepogonEntityKill(ent);
    return 0;
}

void PushEntity(lua_State *L, uintptr_t ent) {
    if (!ent) { lua_pushnil(L); return; }
    lua_newtable(L);
    lua_pushinteger(L, static_cast<lua_Integer>(ent));
    lua_setfield(L, -2, "__ptr");
    luaL_getmetatable(L, "IsaacEntity");
    lua_setmetatable(L, -2);
}

#pragma mark - EntityPlayer Metatable

static int Player_index(lua_State *L) {
    uintptr_t player = CheckEntityPtr(L, 1);
    const char *key = luaL_checkstring(L, 2);
    if (!player) return 0;

    if (strcmp(key, "Damage") == 0) {
        lua_pushnumber(L, RepogonPlayerGetDamage(player)); return 1;
    } else if (strcmp(key, "MoveSpeed") == 0) {
        lua_pushnumber(L, RepogonPlayerGetMoveSpeed(player)); return 1;
    }

    // Check Player metatable methods first
    luaL_getmetatable(L, "IsaacPlayer");
    lua_pushvalue(L, 2);
    lua_rawget(L, -2);
    if (!lua_isnil(L, -1)) return 1;
    lua_pop(L, 2);

    // Fall back to Entity indexing
    return Entity_index(L);
}

static int Player_GetHearts(lua_State *L) {
    uintptr_t p = CheckEntityPtr(L, 1);
    lua_pushinteger(L, p ? RepogonPlayerGetHearts(p) : 0);
    return 1;
}

static int Player_GetMaxHearts(lua_State *L) {
    uintptr_t p = CheckEntityPtr(L, 1);
    lua_pushinteger(L, p ? RepogonPlayerGetMaxHearts(p) : 0);
    return 1;
}

static int Player_GetSoulHearts(lua_State *L) {
    uintptr_t p = CheckEntityPtr(L, 1);
    lua_pushinteger(L, p ? RepogonPlayerGetSoulHearts(p) : 0);
    return 1;
}

static int Player_GetBlackHearts(lua_State *L) {
    uintptr_t p = CheckEntityPtr(L, 1);
    lua_pushinteger(L, p ? RepogonPlayerGetBlackHearts(p) : 0);
    return 1;
}

static int Player_GetBoneHearts(lua_State *L) {
    uintptr_t p = CheckEntityPtr(L, 1);
    lua_pushinteger(L, p ? RepogonPlayerGetBoneHearts(p) : 0);
    return 1;
}

static int Player_AddHearts(lua_State *L) {
    uintptr_t p = CheckEntityPtr(L, 1);
    int32_t val = static_cast<int32_t>(luaL_checkinteger(L, 2));
    if (p) RepogonPlayerSetHearts(p, RepogonPlayerGetHearts(p) + val);
    return 0;
}

static int Player_AddMaxHearts(lua_State *L) {
    uintptr_t p = CheckEntityPtr(L, 1);
    int32_t val = static_cast<int32_t>(luaL_checkinteger(L, 2));
    if (p) RepogonPlayerSetMaxHearts(p, RepogonPlayerGetMaxHearts(p) + val);
    return 0;
}

static int Player_AddSoulHearts(lua_State *L) {
    uintptr_t p = CheckEntityPtr(L, 1);
    int32_t val = static_cast<int32_t>(luaL_checkinteger(L, 2));
    if (p) RepogonPlayerSetSoulHearts(p, RepogonPlayerGetSoulHearts(p) + val);
    return 0;
}

static int Player_AddBlackHearts(lua_State *L) {
    uintptr_t p = CheckEntityPtr(L, 1);
    int32_t val = static_cast<int32_t>(luaL_checkinteger(L, 2));
    if (p) RepogonPlayerSetBlackHearts(p, RepogonPlayerGetBlackHearts(p) + val);
    return 0;
}

static int Player_AddBoneHearts(lua_State *L) {
    uintptr_t p = CheckEntityPtr(L, 1);
    int32_t val = static_cast<int32_t>(luaL_checkinteger(L, 2));
    if (p) RepogonPlayerSetBoneHearts(p, RepogonPlayerGetBoneHearts(p) + val);
    return 0;
}

static int Player_GetNumCoins(lua_State *L) {
    uintptr_t p = CheckEntityPtr(L, 1);
    lua_pushinteger(L, p ? RepogonPlayerGetCoins(p) : 0);
    return 1;
}

static int Player_AddCoins(lua_State *L) {
    uintptr_t p = CheckEntityPtr(L, 1);
    int32_t val = static_cast<int32_t>(luaL_checkinteger(L, 2));
    if (p) RepogonPlayerAddCoins(p, val);
    return 0;
}

static int Player_GetNumBombs(lua_State *L) {
    uintptr_t p = CheckEntityPtr(L, 1);
    lua_pushinteger(L, p ? RepogonPlayerGetBombs(p) : 0);
    return 1;
}

static int Player_AddBombs(lua_State *L) {
    uintptr_t p = CheckEntityPtr(L, 1);
    int32_t val = static_cast<int32_t>(luaL_checkinteger(L, 2));
    if (p) RepogonPlayerAddBombs(p, val);
    return 0;
}

static int Player_GetNumKeys(lua_State *L) {
    uintptr_t p = CheckEntityPtr(L, 1);
    lua_pushinteger(L, p ? RepogonPlayerGetKeys(p) : 0);
    return 1;
}

static int Player_AddKeys(lua_State *L) {
    uintptr_t p = CheckEntityPtr(L, 1);
    int32_t val = static_cast<int32_t>(luaL_checkinteger(L, 2));
    if (p) RepogonPlayerAddKeys(p, val);
    return 0;
}

static int Player_GetActiveItem(lua_State *L) {
    uintptr_t p = CheckEntityPtr(L, 1);
    int slot = static_cast<int>(luaL_optinteger(L, 2, 0));
    lua_pushinteger(L, p ? RepogonPlayerGetActiveItem(p, slot) : 0);
    return 1;
}

static int Player_GetActiveCharge(lua_State *L) {
    uintptr_t p = CheckEntityPtr(L, 1);
    int slot = static_cast<int>(luaL_optinteger(L, 2, 0));
    lua_pushinteger(L, p ? RepogonPlayerGetActiveCharge(p, slot) : 0);
    return 1;
}

static int Player_SetActiveCharge(lua_State *L) {
    uintptr_t p = CheckEntityPtr(L, 1);
    int charge = static_cast<int>(luaL_checkinteger(L, 2));
    int slot = static_cast<int>(luaL_optinteger(L, 3, 0));
    if (p) RepogonPlayerSetActiveCharge(p, charge, slot);
    return 0;
}

static int Player_GetPlayerType(lua_State *L) {
    uintptr_t p = CheckEntityPtr(L, 1);
    lua_pushinteger(L, p ? RepogonPlayerGetType(p) : 0);
    return 1;
}

static int Player_GetName(lua_State *L) {
    lua_pushstring(L, "Isaac");
    return 1;
}

static int Player_HasCollectible(lua_State *L) {
    lua_pushboolean(L, 0); // Extended items query
    return 1;
}

void PushPlayer(lua_State *L, uintptr_t player) {
    if (!player) { lua_pushnil(L); return; }
    lua_newtable(L);
    lua_pushinteger(L, static_cast<lua_Integer>(player));
    lua_setfield(L, -2, "__ptr");
    luaL_getmetatable(L, "IsaacPlayer");
    lua_setmetatable(L, -2);
}

#pragma mark - Room & Game Metatables

static int Room_GetType(lua_State *L) {
    lua_pushinteger(L, RepogonRoomGetType());
    return 1;
}

static int Room_GetCenterPos(lua_State *L) {
    Vector2f c = RepogonRoomGetCenterPos();
    PushVector(L, c.x, c.y);
    return 1;
}

static int Room_GetGridIndex(lua_State *L) {
    Vector2f pos = CheckVector(L, 2);
    lua_pushinteger(L, RepogonRoomGetGridIndex(pos));
    return 1;
}

static int Room_IsClear(lua_State *L) {
    lua_pushboolean(L, RepogonRoomIsClear());
    return 1;
}

void PushRoom(lua_State *L, uintptr_t room) {
    if (!room) { lua_pushnil(L); return; }
    lua_newtable(L);
    lua_pushinteger(L, static_cast<lua_Integer>(room));
    lua_setfield(L, -2, "__ptr");
    luaL_getmetatable(L, "IsaacRoom");
    lua_setmetatable(L, -2);
}

static int Game_GetRoom(lua_State *L) {
    PushRoom(L, RepogonGetRoom());
    return 1;
}

static int Game_GetLevel(lua_State *L) {
    PushLevel(L);
    return 1;
}

static int Game_GetFrameCount(lua_State *L) {
    lua_pushinteger(L, RepogonGameGetFrameCount());
    return 1;
}

static int Game_Spawn(lua_State *L) {
    int type = static_cast<int>(luaL_checkinteger(L, 2));
    int variant = static_cast<int>(luaL_checkinteger(L, 3));
    Vector2f pos = CheckVector(L, 4);
    Vector2f vel = CheckVector(L, 5);
    uintptr_t spawner = CheckEntityPtr(L, 6);
    int subType = static_cast<int>(luaL_optinteger(L, 7, 0));
    uint32_t seed = static_cast<uint32_t>(luaL_optinteger(L, 8, 1));

    uintptr_t ent = RepogonGameSpawn(type, variant, pos, vel, spawner, subType, seed);
    PushEntity(L, ent);
    return 1;
}

static int Game_GetNumPlayers(lua_State *L) {
    lua_pushinteger(L, 1);
    return 1;
}

void PushGame(lua_State *L, uintptr_t game) {
    if (!game) { lua_pushnil(L); return; }
    lua_newtable(L);
    lua_pushinteger(L, static_cast<lua_Integer>(game));
    lua_setfield(L, -2, "__ptr");
    luaL_getmetatable(L, "IsaacGame");
    lua_setmetatable(L, -2);
}

static int Level_GetStage(lua_State *L) {
    lua_pushinteger(L, RepogonGameGetStage());
    return 1;
}

static int Level_GetStageType(lua_State *L) {
    lua_pushinteger(L, RepogonGameGetStageType());
    return 1;
}

static int Level_GetCurrentRoomIndex(lua_State *L) {
    lua_pushinteger(L, 0);
    return 1;
}

static int Level_GetCurses(lua_State *L) {
    lua_pushinteger(L, 0);
    return 1;
}

static int Level_GetPlanetariumChance(lua_State *L) {
    lua_pushnumber(L, 0.01);
    return 1;
}

void PushLevel(lua_State *L) {
    lua_newtable(L);
    luaL_getmetatable(L, "IsaacLevel");
    lua_setmetatable(L, -2);
}

#pragma mark - Isaac Global Table

static int Isaac_DebugString(lua_State *L) {
    const char *msg = luaL_checkstring(L, 1);
    RepogonLogRaw(msg);
    return 0;
}

static int Isaac_GetPlayer(lua_State *L) {
    int idx = static_cast<int>(luaL_optinteger(L, 1, 0));
    uintptr_t p = RepogonGetPlayer(idx);
    PushPlayer(L, p);
    return 1;
}

static int Isaac_GetRoom(lua_State *L) {
    PushRoom(L, RepogonGetRoom());
    return 1;
}

static int Isaac_GetGame(lua_State *L) {
    PushGame(L, RepogonGetGame());
    return 1;
}

static int Isaac_Spawn(lua_State *L) {
    int type = static_cast<int>(luaL_checkinteger(L, 1));
    int variant = static_cast<int>(luaL_checkinteger(L, 2));
    int subType = static_cast<int>(luaL_checkinteger(L, 3));
    Vector2f pos = CheckVector(L, 4);
    Vector2f vel = CheckVector(L, 5);
    uintptr_t spawner = CheckEntityPtr(L, 6);

    uintptr_t ent = RepogonGameSpawn(type, variant, pos, vel, spawner, subType, 1);
    PushEntity(L, ent);
    return 1;
}

static int Isaac_FindByType(lua_State *L) {
    int type = static_cast<int>(luaL_checkinteger(L, 1));
    int variant = static_cast<int>(luaL_optinteger(L, 2, -1));
    int subType = static_cast<int>(luaL_optinteger(L, 3, -1));

    std::vector<uintptr_t> ents = RepogonFindEntities(type, variant, subType);
    lua_newtable(L);
    for (size_t i = 0; i < ents.size(); ++i) {
        PushEntity(L, ents[i]);
        lua_rawseti(L, -2, static_cast<lua_Integer>(i + 1));
    }
    return 1;
}

static int Isaac_CountEntities(lua_State *L) {
    uintptr_t spawner = CheckEntityPtr(L, 1);
    int type = static_cast<int>(luaL_optinteger(L, 2, -1));
    int variant = static_cast<int>(luaL_optinteger(L, 3, -1));
    int subType = static_cast<int>(luaL_optinteger(L, 4, -1));
    std::vector<uintptr_t> ents = RepogonFindEntities(type, variant, subType);
    lua_pushinteger(L, ents.size());
    return 1;
}

static int Isaac_RenderText(lua_State *L) {
    const char *text = luaL_checkstring(L, 1);
    float x = static_cast<float>(luaL_checknumber(L, 2));
    float y = static_cast<float>(luaL_checknumber(L, 3));
    float r = static_cast<float>(luaL_optnumber(L, 4, 1.0));
    float g = static_cast<float>(luaL_optnumber(L, 5, 1.0));
    float b = static_cast<float>(luaL_optnumber(L, 6, 1.0));
    float a = static_cast<float>(luaL_optnumber(L, 7, 1.0));
    RepogonOverlayAddText([NSString stringWithUTF8String:text], x, y, r, g, b, a);
    return 0;
}

static int Isaac_RenderScaledText(lua_State *L) {
    const char *text = luaL_checkstring(L, 1);
    float x = static_cast<float>(luaL_checknumber(L, 2));
    float y = static_cast<float>(luaL_checknumber(L, 3));
    float sx = static_cast<float>(luaL_checknumber(L, 4));
    float sy = static_cast<float>(luaL_checknumber(L, 5));
    float r = static_cast<float>(luaL_optnumber(L, 6, 1.0));
    float g = static_cast<float>(luaL_optnumber(L, 7, 1.0));
    float b = static_cast<float>(luaL_optnumber(L, 8, 1.0));
    float a = static_cast<float>(luaL_optnumber(L, 9, 1.0));
    RepogonOverlayAddScaledText([NSString stringWithUTF8String:text], x, y, sx, sy, r, g, b, a);
    return 0;
}

static int Isaac_WorldToScreen(lua_State *L) {
    Vector2f v = CheckVector(L, 1);
    PushVector(L, v.x, v.y);
    return 1;
}

static int Isaac_ScreenToWorld(lua_State *L) {
    Vector2f v = CheckVector(L, 1);
    PushVector(L, v.x, v.y);
    return 1;
}

static int Isaac_GetItemIdByName(lua_State *L) {
    lua_pushinteger(L, -1);
    return 1;
}

static int Isaac_GetTrinketIdByName(lua_State *L) {
    lua_pushinteger(L, -1);
    return 1;
}

static int Isaac_GetCardIdByName(lua_State *L) {
    lua_pushinteger(L, -1);
    return 1;
}

static int Isaac_GetPillEffectIdByName(lua_State *L) {
    lua_pushinteger(L, -1);
    return 1;
}

static int Isaac_GetItemConfig(lua_State *L) {
    lua_newtable(L);
    lua_pushcfunction(L, [](lua_State *st) -> int {
        lua_newtable(st);
        lua_pushinteger(st, 730); lua_setfield(st, -2, "Size");
        return 1;
    });
    lua_setfield(L, -2, "GetCollectibles");

    lua_pushcfunction(L, [](lua_State *st) -> int {
        lua_newtable(st);
        lua_pushinteger(st, 190); lua_setfield(st, -2, "Size");
        return 1;
    });
    lua_setfield(L, -2, "GetTrinkets");

    lua_pushcfunction(L, [](lua_State *st) -> int {
        lua_newtable(st);
        lua_pushinteger(st, 90); lua_setfield(st, -2, "Size");
        return 1;
    });
    lua_setfield(L, -2, "GetCards");

    lua_pushcfunction(L, [](lua_State *st) -> int {
        lua_newtable(st);
        return 1;
    });
    lua_setfield(L, -2, "GetCollectible");
    return 1;
}

#pragma mark - RegisterMod and Mod Callback Handling

static int Mod_AddCallback(lua_State *L) {
    // mod:AddCallback(callbackId, func, [param])
    lua_getfield(L, 1, "Name");
    std::string modName = luaL_optstring(L, -1, "UnknownMod");
    lua_pop(L, 1);

    int callbackId = static_cast<int>(luaL_checkinteger(L, 2));
    luaL_checktype(L, 3, LUA_TFUNCTION);
    int param = static_cast<int>(luaL_optinteger(L, 4, -1));

    lua_pushvalue(L, 3);
    int funcRef = luaL_ref(L, LUA_REGISTRYINDEX);

    CallbackEntry entry;
    entry.modName = modName;
    entry.funcRef = funcRef;
    entry.param = param;

    g_callbacks[callbackId].push_back(entry);
    RepogonLog(@"Registered callback %d for mod [%s]", callbackId, modName.c_str());
    return 0;
}

static int Mod_RemoveCallback(lua_State *L) {
    // mod:RemoveCallback(callbackId, func)
    int callbackId = static_cast<int>(luaL_checkinteger(L, 2));
    auto it = g_callbacks.find(callbackId);
    if (it != g_callbacks.end()) {
        for (auto eit = it->second.begin(); eit != it->second.end(); ++eit) {
            lua_rawgeti(L, LUA_REGISTRYINDEX, eit->funcRef);
            bool same = lua_rawequal(L, -1, 3);
            lua_pop(L, 1);
            if (same) {
                luaL_unref(L, LUA_REGISTRYINDEX, eit->funcRef);
                it->second.erase(eit);
                break;
            }
        }
    }
    return 0;
}

static int Mod_SaveData(lua_State *L) {
    lua_getfield(L, 1, "Name");
    NSString *modName = [NSString stringWithUTF8String:luaL_optstring(L, -1, "UnknownMod")];
    lua_pop(L, 1);

    const char *data = luaL_checkstring(L, 2);
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *savePath = [paths.firstObject stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_save.dat", modName]];
    [[NSString stringWithUTF8String:data] writeToFile:savePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return 0;
}

static int Mod_LoadData(lua_State *L) {
    lua_getfield(L, 1, "Name");
    NSString *modName = [NSString stringWithUTF8String:luaL_optstring(L, -1, "UnknownMod")];
    lua_pop(L, 1);

    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *savePath = [paths.firstObject stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_save.dat", modName]];
    NSString *data = [NSString stringWithContentsOfFile:savePath encoding:NSUTF8StringEncoding error:nil];
    if (data) {
        lua_pushstring(L, data.UTF8String);
    } else {
        lua_pushstring(L, "");
    }
    return 1;
}

static int Mod_HasData(lua_State *L) {
    lua_getfield(L, 1, "Name");
    NSString *modName = [NSString stringWithUTF8String:luaL_optstring(L, -1, "UnknownMod")];
    lua_pop(L, 1);

    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *savePath = [paths.firstObject stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_save.dat", modName]];
    lua_pushboolean(L, [[NSFileManager defaultManager] fileExistsAtPath:savePath]);
    return 1;
}

static int Mod_RemoveData(lua_State *L) {
    lua_getfield(L, 1, "Name");
    NSString *modName = [NSString stringWithUTF8String:luaL_optstring(L, -1, "UnknownMod")];
    lua_pop(L, 1);

    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *savePath = [paths.firstObject stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_save.dat", modName]];
    [[NSFileManager defaultManager] removeItemAtPath:savePath error:nil];
    return 0;
}

static int RegisterMod_fn(lua_State *L) {
    const char *name = luaL_checkstring(L, 1);
    int apiVersion = static_cast<int>(luaL_optinteger(L, 2, 1));

    lua_newtable(L);
    lua_pushstring(L, name); lua_setfield(L, -2, "Name");
    lua_pushinteger(L, apiVersion); lua_setfield(L, -2, "ApiVersion");

    lua_pushcfunction(L, Mod_AddCallback); lua_setfield(L, -2, "AddCallback");
    lua_pushcfunction(L, Mod_RemoveCallback); lua_setfield(L, -2, "RemoveCallback");
    lua_pushcfunction(L, Mod_SaveData); lua_setfield(L, -2, "SaveData");
    lua_pushcfunction(L, Mod_LoadData); lua_setfield(L, -2, "LoadData");
    lua_pushcfunction(L, Mod_HasData); lua_setfield(L, -2, "HasData");
    lua_pushcfunction(L, Mod_RemoveData); lua_setfield(L, -2, "RemoveData");

    RepogonLog(@"RegisterMod(\"%s\", %d) created mod table.", name, apiVersion);
    return 1;
}

} // namespace

#pragma mark - Lua Runtime Setup & Lifecycle

bool RepogonLuaInit(void) {
    if (g_L) return true;
    g_L = luaL_newstate();
    if (!g_L) {
        RepogonLog(@"Failed to create lua_State!");
        return false;
    }
    luaL_openlibs(g_L);

    // Override global print
    lua_pushcfunction(g_L, LuaPrint);
    lua_setglobal(g_L, "print");

    // Global include
    lua_pushcfunction(g_L, LuaInclude);
    lua_setglobal(g_L, "include");

    // Preload json library
    if (kJsonLuaSource) {
        luaL_dostring(g_L, kJsonLuaSource);
    }

    // Dynamic enum tables with fallback metatable
    luaL_dostring(g_L,
        "local meta = { __index = function(t, k) return 1 end }\n"
        "CollectibleType = setmetatable({ COLLECTIBLE_KEY_PIECE_1 = 238, COLLECTIBLE_KEY_PIECE_2 = 239 }, meta)\n"
        "TrinketType = setmetatable({}, meta)\n"
        "Card = setmetatable({}, meta)\n"
        "PillEffect = setmetatable({}, meta)\n"
        "ButtonAction = setmetatable({}, meta)\n"
        "Keyboard = setmetatable({}, meta)\n"
    );

    // Global RegisterMod
    lua_pushcfunction(g_L, RegisterMod_fn);
    lua_setglobal(g_L, "RegisterMod");

    // Global constructors
    lua_pushcfunction(g_L, Vector_new); lua_setglobal(g_L, "Vector");
    lua_pushcfunction(g_L, KColor_new); lua_setglobal(g_L, "KColor");
    lua_pushcfunction(g_L, Font_new); lua_setglobal(g_L, "Font");
    lua_pushcfunction(g_L, Sprite_new); lua_setglobal(g_L, "Sprite");
    lua_pushcfunction(g_L, [](lua_State *st) -> int {
        PushGame(st, RepogonGetGame());
        return 1;
    });
    lua_setglobal(g_L, "Game");

    // Setup Metatables
    // 1. IsaacVector
    luaL_newmetatable(g_L, "IsaacVector");
    lua_pushcfunction(g_L, Vector_add); lua_setfield(g_L, -2, "__add");
    lua_pushcfunction(g_L, Vector_sub); lua_setfield(g_L, -2, "__sub");
    lua_pushcfunction(g_L, Vector_mul); lua_setfield(g_L, -2, "__mul");
    lua_pushcfunction(g_L, Vector_div); lua_setfield(g_L, -2, "__div");
    lua_pushcfunction(g_L, Vector_unm); lua_setfield(g_L, -2, "__unm");
    lua_pushcfunction(g_L, Vector_tostring); lua_setfield(g_L, -2, "__tostring");
    lua_pushcfunction(g_L, Vector_Length); lua_setfield(g_L, -2, "Length");
    lua_pushcfunction(g_L, Vector_LengthSquared); lua_setfield(g_L, -2, "LengthSquared");
    lua_pushcfunction(g_L, Vector_Normalized); lua_setfield(g_L, -2, "Normalized");
    lua_pushcfunction(g_L, Vector_Distance); lua_setfield(g_L, -2, "Distance");
    lua_pushcfunction(g_L, Vector_Dot); lua_setfield(g_L, -2, "Dot");
    lua_pushcfunction(g_L, Vector_Rotated); lua_setfield(g_L, -2, "Rotated");
    lua_pushvalue(g_L, -1); lua_setfield(g_L, -2, "__index");
    lua_pop(g_L, 1);

    // 2. IsaacEntity
    luaL_newmetatable(g_L, "IsaacEntity");
    lua_pushcfunction(g_L, Entity_index); lua_setfield(g_L, -2, "__index");
    lua_pushcfunction(g_L, Entity_newindex); lua_setfield(g_L, -2, "__newindex");
    lua_pushcfunction(g_L, Entity_GetData); lua_setfield(g_L, -2, "GetData");
    lua_pushcfunction(g_L, Entity_ToPlayer); lua_setfield(g_L, -2, "ToPlayer");
    lua_pushcfunction(g_L, Entity_Kill); lua_setfield(g_L, -2, "Kill");
    lua_pushcfunction(g_L, Entity_Remove); lua_setfield(g_L, -2, "Remove");
    lua_pop(g_L, 1);

    // 3. IsaacPlayer
    luaL_newmetatable(g_L, "IsaacPlayer");
    lua_pushcfunction(g_L, Player_index); lua_setfield(g_L, -2, "__index");
    lua_pushcfunction(g_L, Player_GetHearts); lua_setfield(g_L, -2, "GetHearts");
    lua_pushcfunction(g_L, Player_GetMaxHearts); lua_setfield(g_L, -2, "GetMaxHearts");
    lua_pushcfunction(g_L, Player_GetSoulHearts); lua_setfield(g_L, -2, "GetSoulHearts");
    lua_pushcfunction(g_L, Player_GetBlackHearts); lua_setfield(g_L, -2, "GetBlackHearts");
    lua_pushcfunction(g_L, Player_GetBoneHearts); lua_setfield(g_L, -2, "GetBoneHearts");
    lua_pushcfunction(g_L, Player_AddHearts); lua_setfield(g_L, -2, "AddHearts");
    lua_pushcfunction(g_L, Player_AddMaxHearts); lua_setfield(g_L, -2, "AddMaxHearts");
    lua_pushcfunction(g_L, Player_AddSoulHearts); lua_setfield(g_L, -2, "AddSoulHearts");
    lua_pushcfunction(g_L, Player_AddBlackHearts); lua_setfield(g_L, -2, "AddBlackHearts");
    lua_pushcfunction(g_L, Player_AddBoneHearts); lua_setfield(g_L, -2, "AddBoneHearts");
    lua_pushcfunction(g_L, Player_GetNumCoins); lua_setfield(g_L, -2, "GetNumCoins");
    lua_pushcfunction(g_L, Player_AddCoins); lua_setfield(g_L, -2, "AddCoins");
    lua_pushcfunction(g_L, Player_GetNumBombs); lua_setfield(g_L, -2, "GetNumBombs");
    lua_pushcfunction(g_L, Player_AddBombs); lua_setfield(g_L, -2, "AddBombs");
    lua_pushcfunction(g_L, Player_GetNumKeys); lua_setfield(g_L, -2, "GetNumKeys");
    lua_pushcfunction(g_L, Player_AddKeys); lua_setfield(g_L, -2, "AddKeys");
    lua_pushcfunction(g_L, Player_GetActiveItem); lua_setfield(g_L, -2, "GetActiveItem");
    lua_pushcfunction(g_L, Player_GetActiveCharge); lua_setfield(g_L, -2, "GetActiveCharge");
    lua_pushcfunction(g_L, Player_SetActiveCharge); lua_setfield(g_L, -2, "SetActiveCharge");
    lua_pushcfunction(g_L, Player_GetPlayerType); lua_setfield(g_L, -2, "GetPlayerType");
    lua_pushcfunction(g_L, Player_GetName); lua_setfield(g_L, -2, "GetName");
    lua_pushcfunction(g_L, Player_HasCollectible); lua_setfield(g_L, -2, "HasCollectible");
    lua_pop(g_L, 1);

    // 4. IsaacRoom
    luaL_newmetatable(g_L, "IsaacRoom");
    lua_pushcfunction(g_L, Room_GetType); lua_setfield(g_L, -2, "GetType");
    lua_pushcfunction(g_L, Room_GetCenterPos); lua_setfield(g_L, -2, "GetCenterPos");
    lua_pushcfunction(g_L, Room_GetGridIndex); lua_setfield(g_L, -2, "GetGridIndex");
    lua_pushcfunction(g_L, Room_IsClear); lua_setfield(g_L, -2, "IsClear");
    lua_pushvalue(g_L, -1); lua_setfield(g_L, -2, "__index");
    lua_pop(g_L, 1);

    // 5. IsaacGame
    luaL_newmetatable(g_L, "IsaacGame");
    lua_pushcfunction(g_L, Game_GetRoom); lua_setfield(g_L, -2, "GetRoom");
    lua_pushcfunction(g_L, Game_GetLevel); lua_setfield(g_L, -2, "GetLevel");
    lua_pushcfunction(g_L, Game_GetFrameCount); lua_setfield(g_L, -2, "GetFrameCount");
    lua_pushcfunction(g_L, Game_GetNumPlayers); lua_setfield(g_L, -2, "GetNumPlayers");
    lua_pushcfunction(g_L, Game_Spawn); lua_setfield(g_L, -2, "Spawn");
    lua_pushvalue(g_L, -1); lua_setfield(g_L, -2, "__index");
    lua_pop(g_L, 1);

    // 6. IsaacLevel
    luaL_newmetatable(g_L, "IsaacLevel");
    lua_pushcfunction(g_L, Level_GetStage); lua_setfield(g_L, -2, "GetStage");
    lua_pushcfunction(g_L, Level_GetStageType); lua_setfield(g_L, -2, "GetStageType");
    lua_pushcfunction(g_L, Level_GetCurrentRoomIndex); lua_setfield(g_L, -2, "GetCurrentRoomIndex");
    lua_pushcfunction(g_L, Level_GetCurses); lua_setfield(g_L, -2, "GetCurses");
    lua_pushcfunction(g_L, Level_GetPlanetariumChance); lua_setfield(g_L, -2, "GetPlanetariumChance");
    lua_pushvalue(g_L, -1); lua_setfield(g_L, -2, "__index");
    lua_pop(g_L, 1);

    // Create Isaac Global Table
    lua_newtable(g_L);
    lua_pushcfunction(g_L, Isaac_DebugString); lua_setfield(g_L, -2, "DebugString");
    lua_pushcfunction(g_L, Isaac_GetPlayer); lua_setfield(g_L, -2, "GetPlayer");
    lua_pushcfunction(g_L, Isaac_GetRoom); lua_setfield(g_L, -2, "GetRoom");
    lua_pushcfunction(g_L, Isaac_GetGame); lua_setfield(g_L, -2, "GetGame");
    lua_pushcfunction(g_L, Isaac_Spawn); lua_setfield(g_L, -2, "Spawn");
    lua_pushcfunction(g_L, Isaac_FindByType); lua_setfield(g_L, -2, "FindByType");
    lua_pushcfunction(g_L, Isaac_CountEntities); lua_setfield(g_L, -2, "CountEntities");
    lua_pushcfunction(g_L, Isaac_RenderText); lua_setfield(g_L, -2, "RenderText");
    lua_pushcfunction(g_L, Isaac_RenderScaledText); lua_setfield(g_L, -2, "RenderScaledText");
    lua_pushcfunction(g_L, Isaac_WorldToScreen); lua_setfield(g_L, -2, "WorldToScreen");
    lua_pushcfunction(g_L, Isaac_ScreenToWorld); lua_setfield(g_L, -2, "ScreenToWorld");
    lua_pushcfunction(g_L, Isaac_GetItemIdByName); lua_setfield(g_L, -2, "GetItemIdByName");
    lua_pushcfunction(g_L, Isaac_GetTrinketIdByName); lua_setfield(g_L, -2, "GetTrinketIdByName");
    lua_pushcfunction(g_L, Isaac_GetCardIdByName); lua_setfield(g_L, -2, "GetCardIdByName");
    lua_pushcfunction(g_L, Isaac_GetPillEffectIdByName); lua_setfield(g_L, -2, "GetPillEffectIdByName");
    lua_pushcfunction(g_L, Isaac_GetItemConfig); lua_setfield(g_L, -2, "GetItemConfig");
    lua_setglobal(g_L, "Isaac");

    // ModCallbacks Table
    lua_newtable(g_L);
    lua_pushinteger(g_L, 1); lua_setfield(g_L, -2, "MC_POST_UPDATE");
    lua_pushinteger(g_L, 2); lua_setfield(g_L, -2, "MC_POST_RENDER");
    lua_pushinteger(g_L, 3); lua_setfield(g_L, -2, "MC_USE_ITEM");
    lua_pushinteger(g_L, 4); lua_setfield(g_L, -2, "MC_POST_PEFFECT_UPDATE");
    lua_pushinteger(g_L, 5); lua_setfield(g_L, -2, "MC_USE_CARD");
    lua_pushinteger(g_L, 6); lua_setfield(g_L, -2, "MC_FAMILIAR_UPDATE");
    lua_pushinteger(g_L, 7); lua_setfield(g_L, -2, "MC_FAMILIAR_INIT");
    lua_pushinteger(g_L, 8); lua_setfield(g_L, -2, "MC_EVALUATE_CACHE");
    lua_pushinteger(g_L, 9); lua_setfield(g_L, -2, "MC_PLAYER_INIT");
    lua_pushinteger(g_L, 10); lua_setfield(g_L, -2, "MC_USE_PILL");
    lua_pushinteger(g_L, 11); lua_setfield(g_L, -2, "MC_ENTITY_TAKE_DMG");
    lua_pushinteger(g_L, 20); lua_setfield(g_L, -2, "MC_POST_GAME_STARTED");
    lua_pushinteger(g_L, 21); lua_setfield(g_L, -2, "MC_PRE_GAME_EXIT");
    lua_pushinteger(g_L, 22); lua_setfield(g_L, -2, "MC_POST_NEW_ROOM");
    lua_pushinteger(g_L, 23); lua_setfield(g_L, -2, "MC_POST_NEW_LEVEL");
    lua_pushinteger(g_L, 28); lua_setfield(g_L, -2, "MC_POST_NPC_INIT");
    lua_pushinteger(g_L, 29); lua_setfield(g_L, -2, "MC_POST_NPC_UPDATE");
    lua_pushinteger(g_L, 34); lua_setfield(g_L, -2, "MC_POST_PICKUP_INIT");
    lua_pushinteger(g_L, 35); lua_setfield(g_L, -2, "MC_POST_PICKUP_UPDATE");
    lua_pushinteger(g_L, 61); lua_setfield(g_L, -2, "MC_POST_PLAYER_INIT");
    lua_pushinteger(g_L, 62); lua_setfield(g_L, -2, "MC_POST_PLAYER_UPDATE");
    lua_pushinteger(g_L, 63); lua_setfield(g_L, -2, "MC_POST_PLAYER_RENDER");
    lua_pushinteger(g_L, 64); lua_setfield(g_L, -2, "MC_PRE_ROOM_ENTITY_SPAWN");
    lua_pushinteger(g_L, 67); lua_setfield(g_L, -2, "MC_POST_GET_COLLECTIBLE");
    lua_pushinteger(g_L, 70); lua_setfield(g_L, -2, "MC_PRE_USE_ITEM");
    lua_setglobal(g_L, "ModCallbacks");

    // Enums: EntityType
    lua_newtable(g_L);
    lua_pushinteger(g_L, 0); lua_setfield(g_L, -2, "ENTITY_NULL");
    lua_pushinteger(g_L, 1); lua_setfield(g_L, -2, "ENTITY_PLAYER");
    lua_pushinteger(g_L, 2); lua_setfield(g_L, -2, "ENTITY_TEAR");
    lua_pushinteger(g_L, 3); lua_setfield(g_L, -2, "ENTITY_FAMILIAR");
    lua_pushinteger(g_L, 4); lua_setfield(g_L, -2, "ENTITY_BOMB");
    lua_pushinteger(g_L, 5); lua_setfield(g_L, -2, "ENTITY_PICKUP");
    lua_pushinteger(g_L, 6); lua_setfield(g_L, -2, "ENTITY_SLOT");
    lua_pushinteger(g_L, 7); lua_setfield(g_L, -2, "ENTITY_LASER");
    lua_pushinteger(g_L, 8); lua_setfield(g_L, -2, "ENTITY_KNIFE");
    lua_pushinteger(g_L, 9); lua_setfield(g_L, -2, "ENTITY_PROJECTILE");
    lua_setglobal(g_L, "EntityType");

    // Enums: PickupVariant
    lua_newtable(g_L);
    lua_pushinteger(g_L, 10); lua_setfield(g_L, -2, "PICKUP_HEART");
    lua_pushinteger(g_L, 20); lua_setfield(g_L, -2, "PICKUP_COIN");
    lua_pushinteger(g_L, 40); lua_setfield(g_L, -2, "PICKUP_BOMB");
    lua_pushinteger(g_L, 50); lua_setfield(g_L, -2, "PICKUP_KEY");
    lua_pushinteger(g_L, 60); lua_setfield(g_L, -2, "PICKUP_CHEST");
    lua_pushinteger(g_L, 70); lua_setfield(g_L, -2, "PICKUP_BOMBCHEST");
    lua_pushinteger(g_L, 80); lua_setfield(g_L, -2, "PICKUP_SPIKEDCHEST");
    lua_pushinteger(g_L, 90); lua_setfield(g_L, -2, "PICKUP_ETERNALCHEST");
    lua_pushinteger(g_L, 100); lua_setfield(g_L, -2, "PICKUP_COLLECTIBLE");
    lua_pushinteger(g_L, 300); lua_setfield(g_L, -2, "PICKUP_TAROTCARD");
    lua_pushinteger(g_L, 340); lua_setfield(g_L, -2, "PICKUP_BIGCHEST");
    lua_pushinteger(g_L, 370); lua_setfield(g_L, -2, "PICKUP_TROPHY");
    lua_setglobal(g_L, "PickupVariant");

    // Globals flags
    lua_pushboolean(g_L, 1); lua_setglobal(g_L, "REPENTANCE");
    lua_pushboolean(g_L, 1); lua_setglobal(g_L, "REPENTANCE_PLUS");
    lua_pushboolean(g_L, 1); lua_setglobal(g_L, "REPENTOGON");
    lua_pushstring(g_L, "1.0.0-ios"); lua_setglobal(g_L, "REPENTOGON_VERSION");

    RepogonLog(@"RepogonLua runtime initialized successfully.");
    return true;
}

void RepogonLuaShutdown(void) {
    if (g_L) {
        lua_close(g_L);
        g_L = nullptr;
        g_callbacks.clear();
        g_entityDataRefs.clear();
        RepogonLog(@"RepogonLua runtime shutdown.");
    }
}

lua_State *RepogonLuaGetState(void) {
    return g_L;
}

bool RepogonLuaRunFile(const char *filePath) {
    if (!g_L || !filePath) return false;
    int err = luaL_dofile(g_L, filePath);
    if (err != LUA_OK) {
        const char *msg = lua_tostring(g_L, -1);
        RepogonLog(@"Lua Error in [%s]: %s", filePath, msg ? msg : "unknown");
        lua_pop(g_L, 1);
        return false;
    }
    return true;
}

bool RepogonLuaRunString(const char *script) {
    if (!g_L || !script) return false;
    int err = luaL_dostring(g_L, script);
    if (err != LUA_OK) {
        const char *msg = lua_tostring(g_L, -1);
        RepogonLog(@"Lua Error executing string: %s", msg ? msg : "unknown");
        lua_pop(g_L, 1);
        return false;
    }
    return true;
}

#pragma mark - Callback Dispatchers

static void DispatchCallback(int callbackId, std::function<void(lua_State*)> pushArgs) {
    if (!g_L) return;
    auto it = g_callbacks.find(callbackId);
    if (it == g_callbacks.end() || it->second.empty()) return;

    for (const auto &entry : it->second) {
        lua_rawgeti(g_L, LUA_REGISTRYINDEX, entry.funcRef);
        if (!lua_isfunction(g_L, -1)) {
            lua_pop(g_L, 1);
            continue;
        }

        int argCount = 0;
        if (pushArgs) {
            int topBefore = lua_gettop(g_L);
            pushArgs(g_L);
            argCount = lua_gettop(g_L) - topBefore;
        }

        int err = lua_pcall(g_L, argCount, 1, 0);
        if (err != LUA_OK) {
            const char *msg = lua_tostring(g_L, -1);
            RepogonLog(@"Callback Error [%s] (id: %d): %s", entry.modName.c_str(), callbackId, msg ? msg : "unknown");
            lua_pop(g_L, 1);
        } else {
            lua_pop(g_L, 1); // Discard return value
        }
    }
}

void RepogonLuaDispatchUpdate(void) {
    // 1. MC_POST_UPDATE (1)
    DispatchCallback(1, nullptr);

    // 2. MC_POST_PEFFECT_UPDATE (4) for each player
    size_t entCount = RepogonGetEntityCount();
    for (size_t i = 0; i < entCount; ++i) {
        uintptr_t ent = RepogonGetEntityAtIndex(i);
        if (ent && RepogonEntityGetType(ent) == 1) { // Type 1 = Player
            DispatchCallback(4, [ent](lua_State *L) {
                PushPlayer(L, ent);
            });
        }
    }
}

void RepogonLuaDispatchRender(void) {
    RepogonOverlayClear();
    DispatchCallback(2, nullptr); // MC_POST_RENDER (2)
    RepogonOverlayFlush();
}

void RepogonLuaDispatchNewRoom(void) {
    DispatchCallback(22, nullptr); // MC_POST_NEW_ROOM (22)
}

void RepogonLuaDispatchNewLevel(void) {
    DispatchCallback(23, nullptr); // MC_POST_NEW_LEVEL (23)
}

void RepogonLuaDispatchGameStarted(bool isContinued) {
    DispatchCallback(20, [isContinued](lua_State *L) {
        lua_pushboolean(L, isContinued ? 1 : 0);
    });
}

void RepogonLuaDispatchGameExit(bool shouldSave) {
    DispatchCallback(21, [shouldSave](lua_State *L) {
        lua_pushboolean(L, shouldSave ? 1 : 0);
    });
}
