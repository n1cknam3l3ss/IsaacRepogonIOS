#import "RepogonLua.h"
#import "RepogonEngine.h"
#import "RepogonLogger.h"
#import "RepogonOverlay.h"
#import "RepogonXMLMerger.h"
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
    int modRef; // Reference to mod table in LUA_REGISTRYINDEX (self)
    int funcRef;
    int param; // Optional entity type, item ID, or -1
    int priority; // Callback priority (higher priority runs first)
};

static int GetCallbackId(lua_State *L, int index) {
    if (lua_type(L, index) == LUA_TNUMBER) {
        return static_cast<int>(lua_tointeger(L, index));
    } else if (lua_type(L, index) == LUA_TSTRING) {
        const char *str = lua_tostring(L, index);
        lua_getglobal(L, "ModCallbacks");
        if (lua_istable(L, -1)) {
            lua_getfield(L, -1, str);
            if (lua_isnumber(L, -1)) {
                int id = static_cast<int>(lua_tointeger(L, -1));
                lua_pop(L, 2);
                return id;
            }
            lua_pop(L, 1);
        }
        lua_pop(L, 1);
        return static_cast<int>(std::hash<std::string>{}(str));
    }
    return 0;
}

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
    lua_pushnumber(L, x);
    lua_setfield(L, -2, "x");
    lua_pushnumber(L, y);
    lua_setfield(L, -2, "y");
    luaL_getmetatable(L, "IsaacVector");
    lua_setmetatable(L, -2);
}

Vector2f CheckVector(lua_State *L, int index) {
    Vector2f v = {0.0f, 0.0f};
    if (lua_istable(L, index)) {
        lua_getfield(L, index, "X");
        if (lua_isnumber(L, -1)) {
            v.x = static_cast<float>(lua_tonumber(L, -1));
        } else {
            lua_pop(L, 1);
            lua_getfield(L, index, "x");
            if (lua_isnumber(L, -1)) v.x = static_cast<float>(lua_tonumber(L, -1));
        }
        lua_pop(L, 1);

        lua_getfield(L, index, "Y");
        if (lua_isnumber(L, -1)) {
            v.y = static_cast<float>(lua_tonumber(L, -1));
        } else {
            lua_pop(L, 1);
            lua_getfield(L, index, "y");
            if (lua_isnumber(L, -1)) v.y = static_cast<float>(lua_tonumber(L, -1));
        }
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
    lua_pushnumber(L, r); lua_setfield(L, -2, "R");
    lua_pushnumber(L, g); lua_setfield(L, -2, "G");
    lua_pushnumber(L, b); lua_setfield(L, -2, "B");
    lua_pushnumber(L, a); lua_setfield(L, -2, "A");
    lua_pushnumber(L, 0); lua_setfield(L, -2, "RO");
    lua_pushnumber(L, 0); lua_setfield(L, -2, "GO");
    lua_pushnumber(L, 0); lua_setfield(L, -2, "BO");
    return 1;
}

#pragma mark - Stubs for Font and Sprite

static int Font_new(lua_State *L) {
    lua_newtable(L);
    // Method stubs
    lua_pushcfunction(L, [](lua_State *st) -> int { lua_pushboolean(st, 1); return 1; });
    lua_setfield(L, -2, "Load");
    lua_pushcfunction(L, [](lua_State *st) -> int { lua_pushboolean(st, 1); return 1; });
    lua_setfield(L, -2, "IsLoaded");
    lua_pushcfunction(L, [](lua_State *st) -> int { lua_pushnumber(st, 12.0); return 1; });
    lua_setfield(L, -2, "GetLineHeight");

    auto drawStr = [](lua_State *st) -> int {
        const char *txt = luaL_optstring(st, 2, "");
        float x = static_cast<float>(luaL_optnumber(st, 3, 0));
        float y = static_cast<float>(luaL_optnumber(st, 4, 0));
        RepogonOverlayAddText([NSString stringWithUTF8String:txt], x, y, 1.0f, 1.0f, 1.0f, 1.0f);
        return 0;
    };
    lua_pushcfunction(L, drawStr); lua_setfield(L, -2, "DrawString");
    lua_pushcfunction(L, drawStr); lua_setfield(L, -2, "DrawStringUTF8");

    auto drawScaled = [](lua_State *st) -> int {
        const char *txt = luaL_optstring(st, 2, "");
        float sx = static_cast<float>(luaL_optnumber(st, 5, 1.0));
        float sy = static_cast<float>(luaL_optnumber(st, 6, 1.0));
        float x = static_cast<float>(luaL_optnumber(st, 3, 0));
        float y = static_cast<float>(luaL_optnumber(st, 4, 0));
        RepogonOverlayAddScaledText([NSString stringWithUTF8String:txt], x, y, sx, sy, 1.0f, 1.0f, 1.0f, 1.0f);
        return 0;
    };
    lua_pushcfunction(L, drawScaled); lua_setfield(L, -2, "DrawStringScaled");
    lua_pushcfunction(L, drawScaled); lua_setfield(L, -2, "DrawStringScaledUTF8");

    auto getWidth = [](lua_State *st) -> int {
        const char *txt = luaL_optstring(st, 2, "");
        lua_pushnumber(st, strlen(txt) * 6.0f);
        return 1;
    };
    lua_pushcfunction(L, getWidth); lua_setfield(L, -2, "GetStringWidth");
    lua_pushcfunction(L, getWidth); lua_setfield(L, -2, "GetStringWidthUTF8");

    lua_pushcfunction(L, [](lua_State *st) -> int { return 0; });
    lua_setfield(L, -2, "SetMissingCharacter");
    return 1;
}

static int Sprite_new(lua_State *L) {
    lua_newtable(L);
    PushVector(L, 1.0f, 1.0f);
    lua_setfield(L, -2, "Scale");

    auto dummyFunc = [](lua_State *st) -> int { return 0; };
    lua_pushcfunction(L, dummyFunc); lua_setfield(L, -2, "Load");
    lua_pushcfunction(L, dummyFunc); lua_setfield(L, -2, "Play");
    lua_pushcfunction(L, dummyFunc); lua_setfield(L, -2, "SetFrame");
    lua_pushcfunction(L, dummyFunc); lua_setfield(L, -2, "SetLastFrame");
    lua_pushcfunction(L, dummyFunc); lua_setfield(L, -2, "SetAnimation");
    lua_pushcfunction(L, dummyFunc); lua_setfield(L, -2, "Update");
    lua_pushcfunction(L, dummyFunc); lua_setfield(L, -2, "Render");
    lua_pushcfunction(L, dummyFunc); lua_setfield(L, -2, "RenderLayer");
    lua_pushcfunction(L, dummyFunc); lua_setfield(L, -2, "ReplaceSpritesheet");
    lua_pushcfunction(L, dummyFunc); lua_setfield(L, -2, "LoadGraphics");
    lua_pushcfunction(L, dummyFunc); lua_setfield(L, -2, "Reset");
    lua_pushcfunction(L, [](lua_State *st) -> int { lua_pushboolean(st, 1); return 1; }); lua_setfield(L, -2, "IsFinished");
    lua_pushcfunction(L, [](lua_State *st) -> int { lua_pushboolean(st, 1); return 1; }); lua_setfield(L, -2, "IsPlaying");
    lua_pushcfunction(L, [](lua_State *st) -> int { lua_pushstring(st, ""); return 1; }); lua_setfield(L, -2, "GetAnimation");
    lua_pushcfunction(L, [](lua_State *st) -> int { lua_pushinteger(st, 0); return 1; }); lua_setfield(L, -2, "GetFrame");
    lua_pushcfunction(L, [](lua_State *st) -> int { lua_pushstring(st, ""); return 1; }); lua_setfield(L, -2, "GetFilename");
    lua_pushcfunction(L, dummyFunc); lua_setfield(L, -2, "Colorize");
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

    // Check entity metatable methods first
    luaL_getmetatable(L, "IsaacEntity");
    lua_pushvalue(L, 2);
    lua_rawget(L, -2);
    if (!lua_isnil(L, -1)) return 1;
    lua_pop(L, 2);

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

    return 0;
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

static int Entity_Exists(lua_State *L) {
    uintptr_t ent = CheckEntityPtr(L, 1);
    lua_pushboolean(L, ent != 0);
    return 1;
}

static int Entity_IsDead(lua_State *L) {
    lua_pushboolean(L, 0);
    return 1;
}

static int Entity_IsActive(lua_State *L) {
    lua_pushboolean(L, 1);
    return 1;
}

static int Entity_HasEntityFlags(lua_State *L) {
    lua_pushboolean(L, 0);
    return 1;
}

static int Entity_AddEntityFlags(lua_State *L) {
    return 0;
}

static int Entity_ClearEntityFlags(lua_State *L) {
    return 0;
}

static int Entity_GetSprite(lua_State *L) {
    return Sprite_new(L);
}

static int Entity_GetColor(lua_State *L) {
    return KColor_new(L);
}

static int Entity_SetColor(lua_State *L) {
    return 0;
}

static int Entity_GetDropRNG(lua_State *L) {
    lua_newtable(L);
    lua_pushcfunction(L, [](lua_State *st) -> int { return 0; }); lua_setfield(L, -2, "SetSeed");
    lua_pushcfunction(L, [](lua_State *st) -> int { lua_pushinteger(st, rand()); return 1; }); lua_setfield(L, -2, "Next");
    lua_pushcfunction(L, [](lua_State *st) -> int {
        int max = static_cast<int>(luaL_optinteger(st, 2, 100));
        lua_pushinteger(st, max > 0 ? (rand() % max) : 0);
        return 1;
    }); lua_setfield(L, -2, "RandomInt");
    return 1;
}

static int Entity_ToFamiliar(lua_State *L) {
    lua_pushnil(L);
    return 1;
}

static int Entity_ToNPC(lua_State *L) {
    lua_pushnil(L);
    return 1;
}

static int Entity_ToBomb(lua_State *L) {
    lua_pushnil(L);
    return 1;
}

static int Entity_ToPickup(lua_State *L) {
    lua_pushnil(L);
    return 1;
}

static int Entity_ToTear(lua_State *L) {
    lua_pushnil(L);
    return 1;
}

static int Entity_ToLaser(lua_State *L) {
    lua_pushnil(L);
    return 1;
}

static int Entity_ToKnife(lua_State *L) {
    lua_pushnil(L);
    return 1;
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

    // Check Player metatable methods first
    luaL_getmetatable(L, "IsaacPlayer");
    lua_pushvalue(L, 2);
    lua_rawget(L, -2);
    if (!lua_isnil(L, -1)) return 1;
    lua_pop(L, 2);

    if (player) {
        if (strcmp(key, "Damage") == 0) {
            lua_pushnumber(L, RepogonPlayerGetDamage(player)); return 1;
        } else if (strcmp(key, "MoveSpeed") == 0) {
            lua_pushnumber(L, RepogonPlayerGetMoveSpeed(player)); return 1;
        }
    }

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
    lua_pushboolean(L, 0);
    return 1;
}

static int PushDummyRNG(lua_State *L) {
    lua_newtable(L);
    lua_pushcfunction(L, [](lua_State *st) -> int { return 0; }); lua_setfield(L, -2, "SetSeed");
    lua_pushcfunction(L, [](lua_State *st) -> int { lua_pushinteger(st, rand()); return 1; }); lua_setfield(L, -2, "Next");
    lua_pushcfunction(L, [](lua_State *st) -> int {
        int max = static_cast<int>(luaL_optinteger(st, 2, 100));
        lua_pushinteger(st, max > 0 ? (rand() % max) : 0);
        return 1;
    }); lua_setfield(L, -2, "RandomInt");
    lua_pushcfunction(L, [](lua_State *st) -> int { lua_pushnumber(st, static_cast<double>(rand()) / RAND_MAX); return 1; }); lua_setfield(L, -2, "RandomFloat");
    return 1;
}

static int Player_GetEffects(lua_State *L) {
    lua_newtable(L);
    lua_pushcfunction(L, [](lua_State *st) -> int { lua_pushboolean(st, 0); return 1; }); lua_setfield(L, -2, "HasCollectibleEffect");
    lua_pushcfunction(L, [](lua_State *st) -> int { lua_pushboolean(st, 0); return 1; }); lua_setfield(L, -2, "HasTrinketEffect");
    lua_pushcfunction(L, [](lua_State *st) -> int { lua_pushboolean(st, 0); return 1; }); lua_setfield(L, -2, "HasNullEffect");
    lua_pushcfunction(L, [](lua_State *st) -> int { return 0; }); lua_setfield(L, -2, "AddCollectibleEffect");
    lua_pushcfunction(L, [](lua_State *st) -> int { return 0; }); lua_setfield(L, -2, "RemoveCollectibleEffect");
    return 1;
}

static int Player_GetTrinketMultiplier(lua_State *L) { lua_pushinteger(L, 1); return 1; }
static int Player_GetCollectibleNum(lua_State *L) {
    lua_pushinteger(L, 0);
    return 1;
}
static int Player_GetSmeltedTrinkets(lua_State *L) { lua_newtable(L); return 1; }
static int Player_GetTrinket(lua_State *L) { lua_pushinteger(L, 0); return 1; }
static int Player_GetCard(lua_State *L) { lua_pushinteger(L, 0); return 1; }
static int Player_GetPill(lua_State *L) { lua_pushinteger(L, 0); return 1; }
static int Player_GetEffectiveMaxHearts(lua_State *L) { lua_pushinteger(L, 6); return 1; }
static int Player_GetBrokenHearts(lua_State *L) { lua_pushinteger(L, 0); return 1; }
static int Player_GetSoulCharge(lua_State *L) { lua_pushinteger(L, 0); return 1; }
static int Player_GetBloodCharge(lua_State *L) { lua_pushinteger(L, 0); return 1; }
static int Player_GetPoopMana(lua_State *L) { lua_pushinteger(L, 0); return 1; }
static int Player_GetPoopSpell(lua_State *L) { lua_pushinteger(L, 0); return 1; }
static int Player_GetPlayerFormCounter(lua_State *L) { lua_pushinteger(L, 0); return 1; }
static int Player_HasPlayerForm(lua_State *L) { lua_pushboolean(L, 0); return 1; }
static int Player_HasGoldenBomb(lua_State *L) { lua_pushboolean(L, 0); return 1; }
static int Player_HasTrinket(lua_State *L) { lua_pushboolean(L, 0); return 1; }
static int Player_IsSubPlayer(lua_State *L) { lua_pushboolean(L, 0); return 1; }
static int Player_CanPickRedHearts(lua_State *L) { lua_pushboolean(L, 1); return 1; }
static int Player_GetBabySkin(lua_State *L) { lua_pushinteger(L, 0); return 1; }
static int Player_GetMainTwin(lua_State *L) { lua_pushvalue(L, 1); return 1; }
static int Player_GetOtherTwin(lua_State *L) { lua_pushnil(L); return 1; }
static int Player_AddCollectible(lua_State *L) { return 0; }
static int Player_RemoveCollectible(lua_State *L) { return 0; }
static int Player_GetZodiacEffect(lua_State *L) { lua_pushinteger(L, 0); return 1; }
static int Player_GetModelingClayEffect(lua_State *L) { lua_pushinteger(L, 0); return 1; }
static int Player_GetGlyphOfBalanceDrop(lua_State *L) { lua_pushinteger(L, 0); return 1; }
static int Player_isMainPlayer(lua_State *L) { lua_pushboolean(L, 1); return 1; }

void PushPlayer(lua_State *L, uintptr_t player) {
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

static int Room_IsFirstVisit(lua_State *L) { lua_pushboolean(L, 0); return 1; }
static int Room_TriggerClear(lua_State *L) { return 0; }
static int Room_GetSpawnSeed(lua_State *L) { lua_pushinteger(L, 1); return 1; }
static int Room_GetDecorationSeed(lua_State *L) { lua_pushinteger(L, 1); return 1; }
static int Room_IsPositionInRoom(lua_State *L) { lua_pushboolean(L, 1); return 1; }
static int Room_Update(lua_State *L) { return 0; }
static int Room_MamaMegaExplosion(lua_State *L) { return 0; }
static int Room_GetRenderMode(lua_State *L) { lua_pushinteger(L, 0); return 1; }
static int Room_RemoveGridEntity(lua_State *L) { return 0; }
static int Room_GetGridPosition(lua_State *L) { PushVector(L, 320.0f, 240.0f); return 1; }
static int Room_HasWater(lua_State *L) { lua_pushboolean(L, 0); return 1; }
static int Room_HasLava(lua_State *L) { lua_pushboolean(L, 0); return 1; }
static int Room_GetFrameCount(lua_State *L) { lua_pushinteger(L, 0); return 1; }
static int Room_GetRandomPosition(lua_State *L) { PushVector(L, 320.0f, 240.0f); return 1; }
static int Room_IsMirrorWorld(lua_State *L) { lua_pushboolean(L, 0); return 1; }
static int Room_GetDoor(lua_State *L) { lua_pushnil(L); return 1; }
static int Room_RemoveDoor(lua_State *L) { return 0; }
static int Room_FindFreeTilePosition(lua_State *L) { PushVector(L, 320.0f, 240.0f); return 1; }
static int Room_GetGridWidth(lua_State *L) { lua_pushinteger(L, 13); return 1; }
static int Room_GetGridHeight(lua_State *L) { lua_pushinteger(L, 7); return 1; }
static int Room_GetGridSize(lua_State *L) { lua_pushinteger(L, 135); return 1; }
static int Room_SetFloorColor(lua_State *L) { return 0; }
static int Room_SetWallColor(lua_State *L) { return 0; }
static int Room_GetBackdropType(lua_State *L) { lua_pushinteger(L, 1); return 1; }
static int Room_GetGridEntity(lua_State *L) { lua_pushnil(L); return 1; }
static int Room_GetRenderScrollOffset(lua_State *L) { PushVector(L, 0.0f, 0.0f); return 1; }
static int Room_IsCurrentRoomLastBoss(lua_State *L) { lua_pushboolean(L, 0); return 1; }
static int Room_GetRoomConfigStage(lua_State *L) { lua_pushinteger(L, 1); return 1; }

void PushRoom(lua_State *L, uintptr_t room) {
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

static int Game_GetHUD(lua_State *L) {
    lua_newtable(L);
    lua_pushcfunction(L, [](lua_State *st) -> int { lua_pushboolean(st, 1); return 1; }); lua_setfield(L, -2, "IsVisible");
    lua_pushcfunction(L, [](lua_State *st) -> int { return 0; }); lua_setfield(L, -2, "SetVisible");
    lua_pushcfunction(L, [](lua_State *st) -> int { return 0; }); lua_setfield(L, -2, "ShowItemText");
    return 1;
}

static int Game_GetSeeds(lua_State *L) {
    lua_newtable(L);
    lua_pushcfunction(L, [](lua_State *st) -> int { lua_pushboolean(st, 0); return 1; }); lua_setfield(L, -2, "HasSeedEffect");
    lua_pushcfunction(L, [](lua_State *st) -> int { lua_pushboolean(st, 0); return 1; }); lua_setfield(L, -2, "IsCustomRun");
    lua_pushcfunction(L, [](lua_State *st) -> int { lua_pushinteger(st, 1); return 1; }); lua_setfield(L, -2, "GetStartSeed");
    lua_pushcfunction(L, [](lua_State *st) -> int { lua_pushinteger(st, 0); return 1; }); lua_setfield(L, -2, "CountSeedEffects");
    lua_pushcfunction(L, [](lua_State *st) -> int { return 0; }); lua_setfield(L, -2, "SetStartSeed");
    lua_pushcfunction(L, [](lua_State *st) -> int { lua_pushstring(st, "DUMMY"); return 1; }); lua_setfield(L, -2, "GetStartSeedString");
    return 1;
}

static int Game_GetItemPool(lua_State *L) {
    lua_newtable(L);
    lua_pushcfunction(L, [](lua_State *st) -> int { lua_pushinteger(st, 1); return 1; }); lua_setfield(L, -2, "GetCollectible");
    return 1;
}

static int Game_IsGreedMode(lua_State *L) {
    lua_pushboolean(L, 0);
    return 1;
}

static int Game_GetStateFlag(lua_State *L) {
    lua_pushboolean(L, 0);
    return 1;
}

static int Game_IsPaused(lua_State *L) {
    lua_pushboolean(L, 0);
    return 1;
}

static int Game_GetVictoryLap(lua_State *L) {
    lua_pushinteger(L, 0);
    return 1;
}

static int Game_index(lua_State *L) {
    const char *key = luaL_checkstring(L, 2);
    luaL_getmetatable(L, "IsaacGame");
    lua_pushvalue(L, 2);
    lua_rawget(L, -2);
    if (!lua_isnil(L, -1)) return 1;
    lua_pop(L, 2);

    if (strcmp(key, "ScreenShakeOffset") == 0) {
        PushVector(L, 0.0f, 0.0f);
        return 1;
    }
    if (strcmp(key, "TimeCounter") == 0) {
        lua_pushinteger(L, RepogonGameGetFrameCount());
        return 1;
    }
    if (strcmp(key, "Difficulty") == 0) {
        lua_pushinteger(L, 0);
        return 1;
    }
    return 0;
}

void PushGame(lua_State *L, uintptr_t game) {
    lua_newtable(L);
    lua_pushinteger(L, static_cast<lua_Integer>(game));
    lua_setfield(L, -2, "__ptr");
    luaL_getmetatable(L, "IsaacGame");
    lua_setmetatable(L, -2);
}

static void PushRoomDesc(lua_State *L, int gridIndex = 0) {
    lua_newtable(L);
    lua_pushinteger(L, gridIndex); lua_setfield(L, -2, "SafeGridIndex");
    lua_pushinteger(L, gridIndex); lua_setfield(L, -2, "GridIndex");
    lua_pushinteger(L, static_cast<lua_Integer>(0x100000 + gridIndex)); lua_setfield(L, -2, "__ptr");
    lua_pushinteger(L, 1); lua_setfield(L, -2, "VisitedCount");
    lua_pushinteger(L, 0); lua_setfield(L, -2, "Flags");
    lua_pushboolean(L, 1); lua_setfield(L, -2, "Clear");

    lua_newtable(L);
    lua_pushinteger(L, 1); lua_setfield(L, -2, "Type");
    lua_pushinteger(L, 1); lua_setfield(L, -2, "Shape");
    lua_pushinteger(L, 0); lua_setfield(L, -2, "Subtype");
    lua_pushstring(L, "Room"); lua_setfield(L, -2, "Name");
    lua_setfield(L, -2, "Data");
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

static int Level_GetCurrentRoomDesc(lua_State *L) {
    PushRoomDesc(L, 0);
    return 1;
}

static int Level_GetLastRoomDesc(lua_State *L) {
    PushRoomDesc(L, 0);
    return 1;
}

static int Level_GetRoomByIdx(lua_State *L) {
    int roomIdx = static_cast<int>(luaL_optinteger(L, 2, 0));
    PushRoomDesc(L, roomIdx);
    return 1;
}

static int Level_GetRooms(lua_State *L) {
    lua_newtable(L);
    lua_pushinteger(L, 1); lua_setfield(L, -2, "Size");
    lua_pushcfunction(L, [](lua_State *st) -> int {
        int idx = static_cast<int>(luaL_optinteger(st, 2, 0));
        PushRoomDesc(st, idx);
        return 1;
    });
    lua_setfield(L, -2, "Get");

    PushRoomDesc(L, 0);
    lua_pushvalue(L, -1);
    lua_rawseti(L, -3, 0);
    lua_rawseti(L, -2, 1);
    return 1;
}

static int Level_GetCurrentRoom(lua_State *L) {
    PushRoom(L, RepogonGetRoom());
    return 1;
}

static int Level_GetStartingRoomIndex(lua_State *L) {
    lua_pushinteger(L, 0);
    return 1;
}

static int Level_GetAbsoluteStage(lua_State *L) {
    lua_pushinteger(L, RepogonGameGetStage());
    return 1;
}

static int Level_IsAscent(lua_State *L) {
    lua_pushboolean(L, 0);
    return 1;
}

static int Level_IsPreAscent(lua_State *L) {
    lua_pushboolean(L, 0);
    return 1;
}

static int Level_UncoverHiddenDoor(lua_State *L) { return 0; }
static int Level_MakeRedRoomDoor(lua_State *L) { return 0; }

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

static int PushDummyItemEntry(lua_State *L) {
    lua_newtable(L);
    lua_pushstring(L, "Item"); lua_setfield(L, -2, "Name");
    lua_pushstring(L, ""); lua_setfield(L, -2, "Description");
    lua_pushboolean(L, 0); lua_setfield(L, -2, "Hidden");
    lua_pushinteger(L, 0); lua_setfield(L, -2, "ID");
    lua_pushinteger(L, 0); lua_setfield(L, -2, "Type");
    lua_pushinteger(L, 0); lua_setfield(L, -2, "InitCharge");
    lua_pushinteger(L, 0); lua_setfield(L, -2, "MaxCharges");
    lua_pushcfunction(L, [](lua_State *st) -> int { lua_pushboolean(st, 1); return 1; });
    lua_setfield(L, -2, "IsAvailable");
    return 1;
}

static int Isaac_GetItemConfig(lua_State *L) {
    lua_newtable(L);
    lua_pushcfunction(L, [](lua_State *st) -> int {
        lua_newtable(st);
        lua_pushinteger(st, 730); lua_setfield(st, -2, "Size");
        lua_pushcfunction(st, PushDummyItemEntry); lua_setfield(st, -2, "Get");
        return 1;
    });
    lua_setfield(L, -2, "GetCollectibles");

    lua_pushcfunction(L, [](lua_State *st) -> int {
        lua_newtable(st);
        lua_pushinteger(st, 190); lua_setfield(st, -2, "Size");
        lua_pushcfunction(st, PushDummyItemEntry); lua_setfield(st, -2, "Get");
        return 1;
    });
    lua_setfield(L, -2, "GetTrinkets");

    lua_pushcfunction(L, [](lua_State *st) -> int {
        lua_newtable(st);
        lua_pushinteger(st, 90); lua_setfield(st, -2, "Size");
        lua_pushcfunction(st, PushDummyItemEntry); lua_setfield(st, -2, "Get");
        return 1;
    });
    lua_setfield(L, -2, "GetCards");

    lua_pushcfunction(L, PushDummyItemEntry); lua_setfield(L, -2, "GetCollectible");
    lua_pushcfunction(L, PushDummyItemEntry); lua_setfield(L, -2, "GetTrinket");
    lua_pushcfunction(L, PushDummyItemEntry); lua_setfield(L, -2, "GetCard");
    lua_pushcfunction(L, PushDummyItemEntry); lua_setfield(L, -2, "GetPillEffect");
    lua_pushcfunction(L, PushDummyItemEntry); lua_setfield(L, -2, "GetNullItem");
    return 1;
}

static int Isaac_ConsoleOutput(lua_State *L) {
    const char *msg = luaL_optstring(L, 1, "");
    RepogonLogRaw(msg);
    return 0;
}

static int Isaac_GetSoundIdByName(lua_State *L) {
    const char *name = luaL_optstring(L, 1, "");
    int id = RepogonGetSoundIdByName(name);
    if (id < 0) {
        id = static_cast<int>(std::hash<std::string>{}(name) & 0x7FFF);
        if (id <= 0) id = 1;
    }
    lua_pushinteger(L, id);
    return 1;
}

static int Isaac_GetMusicIdByName(lua_State *L) {
    const char *name = luaL_optstring(L, 1, "");
    int id = RepogonGetMusicIdByName(name);
    if (id < 0) {
        id = static_cast<int>(std::hash<std::string>{}(name) & 0x7FFF);
        if (id <= 0) id = 1;
    }
    lua_pushinteger(L, id);
    return 1;
}

static int Isaac_GetEntityVariantByName(lua_State *L) {
    const char *name = luaL_optstring(L, 1, "");
    int id = RepogonGetEntityVariantByName(name);
    if (id < 0) {
        id = static_cast<int>(std::hash<std::string>{}(name) & 0x7FFF);
        if (id <= 0) id = 1;
    }
    lua_pushinteger(L, id);
    return 1;
}

static int Isaac_GetEntityTypeByName(lua_State *L) {
    const char *name = luaL_optstring(L, 1, "");
    int id = RepogonGetEntityTypeByName(name);
    if (id < 0) {
        id = static_cast<int>(std::hash<std::string>{}(name) & 0x7FFF);
        if (id <= 0) id = 1;
    }
    lua_pushinteger(L, id);
    return 1;
}

static int Isaac_GetPlayerTypeByName(lua_State *L) {
    const char *name = luaL_optstring(L, 1, "");
    int id = RepogonGetPlayerTypeByName(name);
    if (id < 0) {
        id = static_cast<int>((std::hash<std::string>{}(name) % 100) + 50);
    }
    lua_pushinteger(L, id);
    return 1;
}

static int Isaac_GetCostumeIdByName(lua_State *L) {
    const char *name = luaL_optstring(L, 1, "");
    int id = static_cast<int>(std::hash<std::string>{}(name) & 0x7FFF);
    lua_pushinteger(L, id > 0 ? id : 1);
    return 1;
}

static int Isaac_GetTime(lua_State *L) {
    uint32_t ms = static_cast<uint32_t>([[NSDate date] timeIntervalSince1970] * 1000.0);
    lua_pushinteger(L, ms);
    return 1;
}

static int Isaac_IsInGame(lua_State *L) {
    lua_pushboolean(L, 1);
    return 1;
}

static int Isaac_GetFrameCount(lua_State *L) {
    lua_pushinteger(L, RepogonGameGetFrameCount());
    return 1;
}

static int Isaac_CountBosses(lua_State *L) {
    lua_pushinteger(L, 0);
    return 1;
}

static int Isaac_CountEnemies(lua_State *L) {
    lua_pushinteger(L, 0);
    return 1;
}

static int Isaac_GetRoomEntities(lua_State *L) {
    lua_newtable(L);
    uintptr_t p = RepogonGetPlayer(0);
    if (p) {
        PushPlayer(L, p);
        lua_rawseti(L, -2, 1);
    }
    return 1;
}

static int Isaac_FindInRadius(lua_State *L) {
    lua_newtable(L);
    return 1;
}

static int Isaac_GetChallenge(lua_State *L) {
    lua_pushinteger(L, 0);
    return 1;
}

static int Isaac_WorldToRenderPosition(lua_State *L) {
    Vector2f v = CheckVector(L, 1);
    PushVector(L, v.x, v.y);
    return 1;
}

static int Isaac_ScreenToWorldDistance(lua_State *L) {
    Vector2f v = CheckVector(L, 1);
    PushVector(L, v.x, v.y);
    return 1;
}

static int Isaac_Explode(lua_State *L) {
    return 0;
}

static int Isaac_GridSpawn(lua_State *L) {
    lua_pushnil(L);
    return 1;
}

static int Isaac_ExecuteCommand(lua_State *L) {
    const char *cmd = luaL_optstring(L, 1, "");
    RepogonLog(@"Isaac.ExecuteCommand: %s", cmd);
    lua_pushstring(L, "");
    return 1;
}

static int Isaac_GetPersistentGameData(lua_State *L) {
    lua_newtable(L);
    lua_pushcfunction(L, [](lua_State *st) -> int { lua_pushboolean(st, 1); return 1; }); lua_setfield(L, -2, "Unlocked");
    lua_pushcfunction(L, [](lua_State *st) -> int { lua_pushboolean(st, 1); return 1; }); lua_setfield(L, -2, "IsItemInCollection");
    lua_pushcfunction(L, [](lua_State *st) -> int { lua_pushinteger(st, 1); return 1; }); lua_setfield(L, -2, "GetBestiaryEncounterCount");
    lua_pushcfunction(L, [](lua_State *st) -> int { lua_pushinteger(st, 999); return 1; }); lua_setfield(L, -2, "GetEventCounter");
    return 1;
}

static int Isaac_RunCallback(lua_State *L) {
    int callbackId = GetCallbackId(L, 1);
    auto it = g_callbacks.find(callbackId);
    if (it != g_callbacks.end()) {
        int top = lua_gettop(L);
        for (const auto &entry : it->second) {
            lua_rawgeti(L, LUA_REGISTRYINDEX, entry.funcRef);
            if (!lua_isfunction(L, -1)) {
                lua_pop(L, 1);
                continue;
            }
            lua_rawgeti(L, LUA_REGISTRYINDEX, entry.modRef);
            for (int i = 2; i <= top; ++i) {
                lua_pushvalue(L, i);
            }
            int err = lua_pcall(L, 1 + (top - 1), 1, 0);
            if (err != 0) {
                const char *errStr = lua_tostring(L, -1);
                RepogonLog(@"RunCallback Error [%s] (id: %d): %s", entry.modName.c_str(), callbackId, errStr ? errStr : "unknown");
                lua_pop(L, 1);
            } else {
                if (!lua_isnil(L, -1)) {
                    return 1;
                }
                lua_pop(L, 1);
            }
        }
    }
    return 0;
}

static int Isaac_GetCallbacks(lua_State *L) {
    int callbackId = GetCallbackId(L, 1);
    lua_newtable(L);
    auto it = g_callbacks.find(callbackId);
    if (it != g_callbacks.end()) {
        int idx = 1;
        for (const auto &entry : it->second) {
            lua_newtable(L);
            lua_rawgeti(L, LUA_REGISTRYINDEX, entry.funcRef);
            lua_setfield(L, -2, "Function");
            lua_rawgeti(L, LUA_REGISTRYINDEX, entry.modRef);
            lua_setfield(L, -2, "Mod");
            lua_pushinteger(L, entry.param);
            lua_setfield(L, -2, "Param");
            lua_rawseti(L, -2, idx++);
        }
    }
    return 1;
}

#pragma mark - RegisterMod and Mod Callback Handling

static int Mod_AddCallback(lua_State *L) {
    // mod:AddCallback(callbackId, func, [param])
    lua_getfield(L, 1, "Name");
    std::string modName = luaL_optstring(L, -1, "UnknownMod");
    lua_pop(L, 1);

    int callbackId = GetCallbackId(L, 2);
    if (!lua_isfunction(L, 3)) {
        return luaL_error(L, "bad argument #2 to 'AddCallback' (function expected)");
    }
    int param = static_cast<int>(luaL_optinteger(L, 4, -1));

    // Save mod table reference (self)
    lua_pushvalue(L, 1);
    int modRef = luaL_ref(L, LUA_REGISTRYINDEX);

    // Save callback function reference
    lua_pushvalue(L, 3);
    int funcRef = luaL_ref(L, LUA_REGISTRYINDEX);

    CallbackEntry entry;
    entry.modName = modName;
    entry.modRef = modRef;
    entry.funcRef = funcRef;
    entry.param = param;
    entry.priority = 0;

    g_callbacks[callbackId].push_back(entry);
    std::stable_sort(g_callbacks[callbackId].begin(), g_callbacks[callbackId].end(),
                     [](const CallbackEntry &a, const CallbackEntry &b) {
                         return a.priority > b.priority;
                     });

    RepogonLog(@"Registered callback %d for mod [%s]", callbackId, modName.c_str());
    return 0;
}

static int Mod_AddPriorityCallback(lua_State *L) {
    // mod:AddPriorityCallback(callbackId, priority, func, [param])
    lua_getfield(L, 1, "Name");
    std::string modName = luaL_optstring(L, -1, "UnknownMod");
    lua_pop(L, 1);

    int callbackId = GetCallbackId(L, 2);
    int priority = static_cast<int>(luaL_optinteger(L, 3, 0));
    if (!lua_isfunction(L, 4)) {
        return luaL_error(L, "bad argument #3 to 'AddPriorityCallback' (function expected)");
    }
    int param = static_cast<int>(luaL_optinteger(L, 5, -1));

    lua_pushvalue(L, 1);
    int modRef = luaL_ref(L, LUA_REGISTRYINDEX);

    lua_pushvalue(L, 4);
    int funcRef = luaL_ref(L, LUA_REGISTRYINDEX);

    CallbackEntry entry;
    entry.modName = modName;
    entry.modRef = modRef;
    entry.funcRef = funcRef;
    entry.param = param;
    entry.priority = priority;

    g_callbacks[callbackId].push_back(entry);
    std::stable_sort(g_callbacks[callbackId].begin(), g_callbacks[callbackId].end(),
                     [](const CallbackEntry &a, const CallbackEntry &b) {
                         return a.priority > b.priority;
                     });

    RepogonLog(@"Registered priority callback %d (priority %d) for mod [%s]", callbackId, priority, modName.c_str());
    return 0;
}

static int Mod_RemoveCallback(lua_State *L) {
    // mod:RemoveCallback(callbackId, func)
    int callbackId = GetCallbackId(L, 2);
    auto it = g_callbacks.find(callbackId);
    if (it != g_callbacks.end()) {
        for (auto eit = it->second.begin(); eit != it->second.end(); ++eit) {
            lua_rawgeti(L, LUA_REGISTRYINDEX, eit->funcRef);
            bool same = lua_rawequal(L, -1, 3);
            lua_pop(L, 1);
            if (same) {
                luaL_unref(L, LUA_REGISTRYINDEX, eit->funcRef);
                luaL_unref(L, LUA_REGISTRYINDEX, eit->modRef);
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

static int Isaac_SaveModData(lua_State *L) {
    return Mod_SaveData(L);
}

static int Isaac_LoadModData(lua_State *L) {
    return Mod_LoadData(L);
}

static int Isaac_HasModData(lua_State *L) {
    return Mod_HasData(L);
}

static int RegisterMod_fn(lua_State *L) {
    const char *name = luaL_checkstring(L, 1);
    int apiVersion = static_cast<int>(luaL_optinteger(L, 2, 1));

    lua_newtable(L);
    lua_pushstring(L, name); lua_setfield(L, -2, "Name");
    lua_pushinteger(L, apiVersion); lua_setfield(L, -2, "ApiVersion");

    lua_pushcfunction(L, Mod_AddCallback); lua_setfield(L, -2, "AddCallback");
    lua_pushcfunction(L, Mod_AddPriorityCallback); lua_setfield(L, -2, "AddPriorityCallback");
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
        int err = luaL_dostring(g_L, kJsonLuaSource);
        if (err != LUA_OK) {
            const char *msg = lua_tostring(g_L, -1);
            RepogonLog(@"[RepogonLua] Error loading embedded json module: %s", msg ? msg : "unknown");
            lua_pop(g_L, 1);
        } else {
            RepogonLog(@"[RepogonLua] Embedded json module registered successfully.");
        }
    }

    // Dynamic enum tables and BitSet128 implementation
    const char *kInitScript = R"RAW_INIT(
local BitSet128_mt = {}
BitSet128_mt.__index = BitSet128_mt

function BitSet128_mt:Set(bit)
    if bit < 64 then self.l = self.l | (1 << bit)
    else self.h = self.h | (1 << (bit - 64)) end
    return self
end

function BitSet128_mt:Clear(bit)
    if bit < 64 then self.l = self.l & ~(1 << bit)
    else self.h = self.h & ~(1 << (bit - 64)) end
    return self
end

function BitSet128_mt:Has(bit)
    if bit < 64 then return (self.l & (1 << bit)) ~= 0
    else return (self.h & (1 << (bit - 64))) ~= 0 end
end

function BitSet128_mt:Empty()
    return self.l == 0 and self.h == 0
end

function BitSet128_mt.__bor(a, b)
    local al, ah = (type(a) == 'table' and a.l or a or 0), (type(a) == 'table' and a.h or 0)
    local bl, bh = (type(b) == 'table' and b.l or b or 0), (type(b) == 'table' and b.h or 0)
    return setmetatable({ l = al | bl, h = ah | bh }, BitSet128_mt)
end

function BitSet128_mt.__band(a, b)
    local al, ah = (type(a) == 'table' and a.l or a or 0), (type(a) == 'table' and a.h or 0)
    local bl, bh = (type(b) == 'table' and b.l or b or 0), (type(b) == 'table' and b.h or 0)
    return setmetatable({ l = al & bl, h = ah & bh }, BitSet128_mt)
end

function BitSet128_mt.__bxor(a, b)
    local al, ah = (type(a) == 'table' and a.l or a or 0), (type(a) == 'table' and a.h or 0)
    local bl, bh = (type(b) == 'table' and b.l or b or 0), (type(b) == 'table' and b.h or 0)
    return setmetatable({ l = al ~ bl, h = ah ~ bh }, BitSet128_mt)
end

function BitSet128_mt.__bnot(a)
    return setmetatable({ l = ~a.l, h = ~a.h }, BitSet128_mt)
end

function BitSet128_mt.__eq(a, b)
    if type(a) ~= 'table' or type(b) ~= 'table' then return false end
    return a.l == b.l and a.h == b.h
end

function BitSet128_mt.__tostring(a)
    return string.format('BitSet128(0x%X, 0x%X)', a.l or 0, a.h or 0)
end

BitSet128 = function(l, h)
    return setmetatable({ l = l or 0, h = h or 0 }, BitSet128_mt)
end

local enum_meta = {
    __index = function(t, k)
        if k == 'NUM_PILLS' then return 25 end
        if k == 'NUM_CARDS' then return 90 end
        if k == 'NUM_TRINKETS' then return 189 end
        if k == 'NUM_COLLECTIBLES' then return 732 end
        if type(k) == 'number' then return k end
        local val = rawget(t, '__next_id') or 100
        rawset(t, '__next_id', val + 1)
        rawset(t, k, val)
        return val
    end
}

local function make_enum(tbl)
    return setmetatable(tbl or {}, enum_meta)
end

GetPtrHash = function(ent)
    if type(ent) == "table" then
        return ent.__ptr or (ent.GridIndex and (0x100000 + ent.GridIndex)) or tostring(ent)
    elseif ent ~= nil then
        return tostring(ent)
    else
        return 0
    end
end

EntityPartition = make_enum({
    TEAR = 1,
    FAMILIAR = 2,
    BOMB = 4,
    PICKUP = 8,
    PLAYER = 16,
    ENEMY = 32,
    EFFECT = 64
})
BackdropType = make_enum({})
CallbackPriority = make_enum({
    EARLY = 100,
    IMPORTANT = 10,
    DEFAULT = 0,
    LATE = -100
})

PillColor = make_enum({ PILL_NULL = 0, NUM_PILLS = 25 })
PillEffect = make_enum({ PILLEFFECT_NULL = 0 })
CollectibleType = make_enum({
    COLLECTIBLE_NULL = 0,
    COLLECTIBLE_KEY_PIECE_1 = 238,
    COLLECTIBLE_KEY_PIECE_2 = 239,
    NUM_COLLECTIBLES = 732
})
TrinketType = make_enum({ TRINKET_NULL = 0, NUM_TRINKETS = 189 })
Card = make_enum({ CARD_NULL = 0, NUM_CARDS = 90 })
ItemPoolType = make_enum({ POOL_NULL = -1, POOL_TREASURE = 0 })
RoomType = make_enum({ ROOM_NULL = 0, ROOM_DEFAULT = 1 })
RoomShape = make_enum({ ROOMSHAPE_1x1 = 1 })
DoorSlot = make_enum({ NO_DOOR_SLOT = -1 })
DoorState = make_enum({
    STATE_INIT = 0,
    STATE_CLOSED = 1,
    STATE_OPEN = 2,
    STATE_ONE_CHAIN = 3,
    STATE_WAITING_TO_CLOSE = 4,
    STATE_CLOSING = 5,
    STATE_DESTROYED = 6
})
EffectVariant = make_enum({
    BLOOD_PARTICLE = 1,
    BOMB_EXPLOSION = 2
})
Direction = make_enum({ NO_DIRECTION = -1 })
ButtonAction = make_enum({ ACTION_NULL = -1 })
Keyboard = make_enum({ KEY_NULL = 0 })
Controller = make_enum({})
SoundEffect = make_enum({ SOUND_NULL = 0 })
Music = make_enum({ MUSIC_NULL = 0 })
LevelStage = make_enum({ STAGE_NULL = 0 })
StageType = make_enum({ STAGETYPE_ORIGINAL = 0 })
EntityFlag = make_enum({})
TearFlag = make_enum({
    TEAR_NORMAL = BitSet128(0, 0),
    TEAR_SPECTRAL = BitSet128(1, 0),
    TEAR_PIERCING = BitSet128(2, 0),
    TEAR_HOMING = BitSet128(4, 0)
})
TearVariant = make_enum({ BLUE = 0 })
BombVariant = make_enum({ BOMB_NORMAL = 0 })
BabySubType = make_enum({ BABY_UNASSIGNED = 0 })
PlayerType = make_enum({ PLAYER_ISAAC = 0 })
LaserSubType = make_enum({})
DamageFlag = make_enum({})
UseFlag = make_enum({})
CacheFlag = make_enum({
    CACHE_DAMAGE = 1,
    CACHE_FIREDELAY = 2,
    CACHE_SHOTSPEED = 4,
    CACHE_RANGE = 8,
    CACHE_SPEED = 16,
    CACHE_TEARFLAG = 32,
    CACHE_TEARCOLOR = 64,
    CACHE_FLYING = 128,
    CACHE_WEAPON = 256,
    CACHE_FAMILIARS = 512,
    CACHE_LUCK = 1024,
    CACHE_ALL = 0xFFFFFFFF
})
GridEntityType = make_enum({})
SortingLayer = make_enum({})
Dimension = make_enum({})
SeedEffect = make_enum({})
Challenge = make_enum({ CHALLENGE_NULL = 0 })
ItemType = make_enum({
    ITEM_NULL = 0,
    ITEM_PASSIVE = 1,
    ITEM_ACTIVE = 2,
    ITEM_FAMILIAR = 3,
    ITEM_TRINKET = 4
})
ActiveSlot = make_enum({
    SLOT_PRIMARY = 0,
    SLOT_SECONDARY = 1,
    SLOT_POCKET = 2,
    SLOT_POCKET2 = 3
})
SkinColor = make_enum({
    SKIN_WHITE = 0,
    SKIN_BLACK = 1,
    SKIN_BLUE = 2,
    SKIN_RED = 3,
    SKIN_GREEN = 4,
    SKIN_GREY = 5
})

Options = {
    Language = "en",
    FoundHUD = 1,
    ExtraHUD = 1,
    HUDOffset = 0,
    MusicVolume = 1.0,
    SFXVolume = 1.0,
    Gamma = 1.0,
    Brightness = 1.0,
    Fullscreen = true,
    Filter = false,
    Vsync = true,
    MaxScale = 99,
    MaxRenderScale = 99,
    PauseOnFocusLost = false,
    StatHUDPlanetarium = true
}

ItemConfig = {
    GetItemConfig = function() return Isaac.GetItemConfig() end,
    Config = { GetItemConfig = function() return Isaac.GetItemConfig() end }
}

PlayerForm = make_enum({
    PLAYERFORM_GUPPY = 0,
    PLAYERFORM_LORD_OF_THE_FLIES = 1,
    PLAYERFORM_MUSHROOM = 2,
    PLAYERFORM_ANGEL = 3,
    PLAYERFORM_BOB = 4,
    PLAYERFORM_DRUID = 5,
    PLAYERFORM_CTHULHU = 6,
    PLAYERFORM_SPIDERBABY = 7,
    PLAYERFORM_BOOKWORM = 8,
    PLAYERFORM_ADULT = 9,
    PLAYERFORM_MOM = 10,
    PLAYERFORM_CONJOINED = 11,
    PLAYERFORM_SUPERBUM = 12,
    PLAYERFORM_STOMPY = 13,
    PLAYERFORM_SERAPHIM = 14
})

Input = {
    IsActionPressed = function(a, p) return false end,
    IsActionTriggered = function(a, p) return false end,
    IsButtonPressed = function(b, c) return false end,
    IsButtonTriggered = function(b, c) return false end,
    GetMousePosition = function(r) return { X = 0, Y = 0, x = 0, y = 0 } end
}

MusicManager = function()
    local mgr = {}
    function mgr:GetCurrentMusicID() return 1 end
    function mgr:GetQueuedMusicID() return 0 end
    function mgr:Play(id, vol) end
    function mgr:Queue(id) end
    function mgr:Pause() end
    function mgr:Resume() end
    function mgr:Fadeout(rate) end
    function mgr:Crossfade(id) end
    function mgr:PitchSlide(rate) end
    function mgr:ResetPitch() end
    function mgr:VolumeSlide(vol, rate) end
    function mgr:UpdateVolume() end
    function mgr:EnableLayer(layer) end
    function mgr:DisableLayer(layer) end
    function mgr:IsLayerEnabled(layer) return false end
    function mgr:Enable() end
    function mgr:Disable() end
    function mgr:IsEnabled() return true end
    return mgr
end

SFXManager = function()
    local sfx = {}
    function sfx:Play(id, vol, frameDelay, loop, pitch, pan) end
    function sfx:Stop(id) end
    function sfx:IsPlaying(id) return false end
    function sfx:AdjustPitch(id, pitch) end
    function sfx:AdjustVolume(id, vol) end
    return sfx
end

local rng_mt = {
    __index = {
        SetSeed = function(self, s, shift) end,
        Next = function(self) return math.random(0, 2147483647) end,
        RandomInt = function(self, max) return max and math.random(0, max - 1) or math.random(0, 100) end,
        RandomFloat = function(self) return math.random() end
    }
}
RNG = function()
    return setmetatable({}, rng_mt)
end

REPENTANCE_PLUS = true
FontRenderSettings = function() return {} end
XMLData = {
    GetEntityByTypeVarSub = function(t, v, s) return nil end
}
MainMenuType = make_enum({ COLLECTION = 1 })
MenuManager = {
    GetActiveMenu = function() return -1 end
}
)RAW_INIT";

    int initErr = luaL_dostring(g_L, kInitScript);
    if (initErr != LUA_OK) {
        const char *msg = lua_tostring(g_L, -1);
        RepogonLog(@"[RepogonLua] Error running init script: %s", msg ? msg : "unknown");
        lua_pop(g_L, 1);
    }

    // Global RegisterMod
    lua_pushcfunction(g_L, RegisterMod_fn);
    lua_setglobal(g_L, "RegisterMod");

    // Global constructors
    lua_pushcfunction(g_L, Vector_new); lua_setglobal(g_L, "Vector");
    lua_pushcfunction(g_L, KColor_new); lua_setglobal(g_L, "KColor");
    lua_pushcfunction(g_L, KColor_new); lua_setglobal(g_L, "Color");
    lua_pushcfunction(g_L, Font_new); lua_setglobal(g_L, "Font");
    lua_pushcfunction(g_L, Sprite_new); lua_setglobal(g_L, "Sprite");
    lua_pushcfunction(g_L, [](lua_State *st) -> int {
        PushGame(st, RepogonGetGame());
        return 1;
    });
    lua_setglobal(g_L, "Game");

    const char *kPostInitScript = R"RAW_POST(
local orig_Vector = Vector
Vector = setmetatable({
    Zero = orig_Vector(0, 0),
    One = orig_Vector(1, 1),
    FromAngle = function(deg)
        local rad = math.rad(deg)
        return orig_Vector(math.cos(rad), math.sin(rad))
    end
}, {
    __call = function(_, x, y) return orig_Vector(x, y) end
})

local orig_Game = Game
Game = setmetatable({}, {
    __call = function(_) return orig_Game() end,
    __index = function(_, k)
        local inst = orig_Game()
        local v = inst[k]
        if type(v) == "function" then
            return function(self, ...)
                if self == Game then
                    return v(inst, ...)
                else
                    return v(self, ...)
                end
            end
        end
        return v
    end
})
)RAW_POST";
    luaL_dostring(g_L, kPostInitScript);

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
    lua_pushcfunction(g_L, Entity_ToFamiliar); lua_setfield(g_L, -2, "ToFamiliar");
    lua_pushcfunction(g_L, Entity_ToNPC); lua_setfield(g_L, -2, "ToNPC");
    lua_pushcfunction(g_L, Entity_ToBomb); lua_setfield(g_L, -2, "ToBomb");
    lua_pushcfunction(g_L, Entity_ToPickup); lua_setfield(g_L, -2, "ToPickup");
    lua_pushcfunction(g_L, Entity_ToTear); lua_setfield(g_L, -2, "ToTear");
    lua_pushcfunction(g_L, Entity_ToLaser); lua_setfield(g_L, -2, "ToLaser");
    lua_pushcfunction(g_L, Entity_ToKnife); lua_setfield(g_L, -2, "ToKnife");
    lua_pushcfunction(g_L, Entity_Exists); lua_setfield(g_L, -2, "Exists");
    lua_pushcfunction(g_L, Entity_IsDead); lua_setfield(g_L, -2, "IsDead");
    lua_pushcfunction(g_L, Entity_IsActive); lua_setfield(g_L, -2, "IsActive");
    lua_pushcfunction(g_L, Entity_HasEntityFlags); lua_setfield(g_L, -2, "HasEntityFlags");
    lua_pushcfunction(g_L, Entity_AddEntityFlags); lua_setfield(g_L, -2, "AddEntityFlags");
    lua_pushcfunction(g_L, Entity_ClearEntityFlags); lua_setfield(g_L, -2, "ClearEntityFlags");
    lua_pushcfunction(g_L, Entity_GetSprite); lua_setfield(g_L, -2, "GetSprite");
    lua_pushcfunction(g_L, Entity_GetColor); lua_setfield(g_L, -2, "GetColor");
    lua_pushcfunction(g_L, Entity_SetColor); lua_setfield(g_L, -2, "SetColor");
    lua_pushcfunction(g_L, Entity_GetDropRNG); lua_setfield(g_L, -2, "GetDropRNG");
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
    lua_pushcfunction(g_L, Player_GetEffects); lua_setfield(g_L, -2, "GetEffects");
    lua_pushcfunction(g_L, PushDummyRNG); lua_setfield(g_L, -2, "GetCardRNG");
    lua_pushcfunction(g_L, PushDummyRNG); lua_setfield(g_L, -2, "GetPillRNG");
    lua_pushcfunction(g_L, PushDummyRNG); lua_setfield(g_L, -2, "GetTrinketRNG");
    lua_pushcfunction(g_L, PushDummyRNG); lua_setfield(g_L, -2, "GetCollectibleRNG");
    lua_pushcfunction(g_L, Player_GetTrinketMultiplier); lua_setfield(g_L, -2, "GetTrinketMultiplier");
    lua_pushcfunction(g_L, Player_GetCollectibleNum); lua_setfield(g_L, -2, "GetCollectibleNum");
    lua_pushcfunction(g_L, Player_GetSmeltedTrinkets); lua_setfield(g_L, -2, "GetSmeltedTrinkets");
    lua_pushcfunction(g_L, Player_GetTrinket); lua_setfield(g_L, -2, "GetTrinket");
    lua_pushcfunction(g_L, Player_GetCard); lua_setfield(g_L, -2, "GetCard");
    lua_pushcfunction(g_L, Player_GetPill); lua_setfield(g_L, -2, "GetPill");
    lua_pushcfunction(g_L, Player_GetEffectiveMaxHearts); lua_setfield(g_L, -2, "GetEffectiveMaxHearts");
    lua_pushcfunction(g_L, Player_GetBrokenHearts); lua_setfield(g_L, -2, "GetBrokenHearts");
    lua_pushcfunction(g_L, Player_GetSoulCharge); lua_setfield(g_L, -2, "GetSoulCharge");
    lua_pushcfunction(g_L, Player_GetBloodCharge); lua_setfield(g_L, -2, "GetBloodCharge");
    lua_pushcfunction(g_L, Player_GetPoopMana); lua_setfield(g_L, -2, "GetPoopMana");
    lua_pushcfunction(g_L, Player_GetPoopSpell); lua_setfield(g_L, -2, "GetPoopSpell");
    lua_pushcfunction(g_L, Player_GetPlayerFormCounter); lua_setfield(g_L, -2, "GetPlayerFormCounter");
    lua_pushcfunction(g_L, Player_HasPlayerForm); lua_setfield(g_L, -2, "HasPlayerForm");
    lua_pushcfunction(g_L, Player_HasGoldenBomb); lua_setfield(g_L, -2, "HasGoldenBomb");
    lua_pushcfunction(g_L, Player_HasTrinket); lua_setfield(g_L, -2, "HasTrinket");
    lua_pushcfunction(g_L, Player_IsSubPlayer); lua_setfield(g_L, -2, "IsSubPlayer");
    lua_pushcfunction(g_L, Player_CanPickRedHearts); lua_setfield(g_L, -2, "CanPickRedHearts");
    lua_pushcfunction(g_L, Player_GetBabySkin); lua_setfield(g_L, -2, "GetBabySkin");
    lua_pushcfunction(g_L, Player_GetMainTwin); lua_setfield(g_L, -2, "GetMainTwin");
    lua_pushcfunction(g_L, Player_GetOtherTwin); lua_setfield(g_L, -2, "GetOtherTwin");
    lua_pushcfunction(g_L, Player_AddCollectible); lua_setfield(g_L, -2, "AddCollectible");
    lua_pushcfunction(g_L, Player_RemoveCollectible); lua_setfield(g_L, -2, "RemoveCollectible");
    lua_pushcfunction(g_L, Player_GetZodiacEffect); lua_setfield(g_L, -2, "GetZodiacEffect");
    lua_pushcfunction(g_L, Player_GetModelingClayEffect); lua_setfield(g_L, -2, "GetModelingClayEffect");
    lua_pushcfunction(g_L, Player_GetGlyphOfBalanceDrop); lua_setfield(g_L, -2, "GetGlyphOfBalanceDrop");
    lua_pushcfunction(g_L, Entity_GetSprite); lua_setfield(g_L, -2, "GetSprite");
    lua_pushcfunction(g_L, Player_isMainPlayer); lua_setfield(g_L, -2, "isMainPlayer");
    lua_pop(g_L, 1);

    // 4. IsaacRoom
    luaL_newmetatable(g_L, "IsaacRoom");
    lua_pushcfunction(g_L, Room_GetType); lua_setfield(g_L, -2, "GetType");
    lua_pushcfunction(g_L, Room_GetCenterPos); lua_setfield(g_L, -2, "GetCenterPos");
    lua_pushcfunction(g_L, Room_GetGridIndex); lua_setfield(g_L, -2, "GetGridIndex");
    lua_pushcfunction(g_L, Room_IsClear); lua_setfield(g_L, -2, "IsClear");
    lua_pushcfunction(g_L, Room_IsFirstVisit); lua_setfield(g_L, -2, "IsFirstVisit");
    lua_pushcfunction(g_L, Room_TriggerClear); lua_setfield(g_L, -2, "TriggerClear");
    lua_pushcfunction(g_L, Room_GetSpawnSeed); lua_setfield(g_L, -2, "GetSpawnSeed");
    lua_pushcfunction(g_L, Room_GetDecorationSeed); lua_setfield(g_L, -2, "GetDecorationSeed");
    lua_pushcfunction(g_L, Room_IsPositionInRoom); lua_setfield(g_L, -2, "IsPositionInRoom");
    lua_pushcfunction(g_L, Room_Update); lua_setfield(g_L, -2, "Update");
    lua_pushcfunction(g_L, Room_MamaMegaExplosion); lua_setfield(g_L, -2, "MamaMegaExplosion");
    lua_pushcfunction(g_L, Room_GetRenderMode); lua_setfield(g_L, -2, "GetRenderMode");
    lua_pushcfunction(g_L, Room_RemoveGridEntity); lua_setfield(g_L, -2, "RemoveGridEntity");
    lua_pushcfunction(g_L, Room_GetGridPosition); lua_setfield(g_L, -2, "GetGridPosition");
    lua_pushcfunction(g_L, Room_HasWater); lua_setfield(g_L, -2, "HasWater");
    lua_pushcfunction(g_L, Room_HasLava); lua_setfield(g_L, -2, "HasLava");
    lua_pushcfunction(g_L, Room_GetFrameCount); lua_setfield(g_L, -2, "GetFrameCount");
    lua_pushcfunction(g_L, Room_GetRandomPosition); lua_setfield(g_L, -2, "GetRandomPosition");
    lua_pushcfunction(g_L, Room_IsMirrorWorld); lua_setfield(g_L, -2, "IsMirrorWorld");
    lua_pushcfunction(g_L, Room_GetDoor); lua_setfield(g_L, -2, "GetDoor");
    lua_pushcfunction(g_L, Room_RemoveDoor); lua_setfield(g_L, -2, "RemoveDoor");
    lua_pushcfunction(g_L, Room_FindFreeTilePosition); lua_setfield(g_L, -2, "FindFreeTilePosition");
    lua_pushcfunction(g_L, Room_GetGridWidth); lua_setfield(g_L, -2, "GetGridWidth");
    lua_pushcfunction(g_L, Room_GetGridHeight); lua_setfield(g_L, -2, "GetGridHeight");
    lua_pushcfunction(g_L, Room_GetGridSize); lua_setfield(g_L, -2, "GetGridSize");
    lua_pushcfunction(g_L, Room_SetFloorColor); lua_setfield(g_L, -2, "SetFloorColor");
    lua_pushcfunction(g_L, Room_SetWallColor); lua_setfield(g_L, -2, "SetWallColor");
    lua_pushcfunction(g_L, Room_GetBackdropType); lua_setfield(g_L, -2, "GetBackdropType");
    lua_pushcfunction(g_L, Room_GetGridEntity); lua_setfield(g_L, -2, "GetGridEntity");
    lua_pushcfunction(g_L, Room_GetRenderScrollOffset); lua_setfield(g_L, -2, "GetRenderScrollOffset");
    lua_pushcfunction(g_L, Room_IsCurrentRoomLastBoss); lua_setfield(g_L, -2, "IsCurrentRoomLastBoss");
    lua_pushcfunction(g_L, Room_GetRoomConfigStage); lua_setfield(g_L, -2, "GetRoomConfigStage");
    lua_pushvalue(g_L, -1); lua_setfield(g_L, -2, "__index");
    lua_pop(g_L, 1);

    // 5. IsaacGame
    luaL_newmetatable(g_L, "IsaacGame");
    lua_pushcfunction(g_L, Game_GetRoom); lua_setfield(g_L, -2, "GetRoom");
    lua_pushcfunction(g_L, Game_GetLevel); lua_setfield(g_L, -2, "GetLevel");
    lua_pushcfunction(g_L, Game_GetFrameCount); lua_setfield(g_L, -2, "GetFrameCount");
    lua_pushcfunction(g_L, Game_GetNumPlayers); lua_setfield(g_L, -2, "GetNumPlayers");
    lua_pushcfunction(g_L, Game_Spawn); lua_setfield(g_L, -2, "Spawn");
    lua_pushcfunction(g_L, Game_GetHUD); lua_setfield(g_L, -2, "GetHUD");
    lua_pushcfunction(g_L, Game_GetSeeds); lua_setfield(g_L, -2, "GetSeeds");
    lua_pushcfunction(g_L, Game_GetItemPool); lua_setfield(g_L, -2, "GetItemPool");
    lua_pushcfunction(g_L, Game_IsGreedMode); lua_setfield(g_L, -2, "IsGreedMode");
    lua_pushcfunction(g_L, Game_GetStateFlag); lua_setfield(g_L, -2, "GetStateFlag");
    lua_pushcfunction(g_L, Game_IsPaused); lua_setfield(g_L, -2, "IsPaused");
    lua_pushcfunction(g_L, Game_GetVictoryLap); lua_setfield(g_L, -2, "GetVictoryLap");
    lua_pushcfunction(g_L, Game_index); lua_setfield(g_L, -2, "__index");
    lua_pop(g_L, 1);

    // 6. IsaacLevel
    luaL_newmetatable(g_L, "IsaacLevel");
    lua_pushcfunction(g_L, Level_GetStage); lua_setfield(g_L, -2, "GetStage");
    lua_pushcfunction(g_L, Level_GetStageType); lua_setfield(g_L, -2, "GetStageType");
    lua_pushcfunction(g_L, Level_GetCurrentRoomIndex); lua_setfield(g_L, -2, "GetCurrentRoomIndex");
    lua_pushcfunction(g_L, Level_GetCurses); lua_setfield(g_L, -2, "GetCurses");
    lua_pushcfunction(g_L, Level_GetPlanetariumChance); lua_setfield(g_L, -2, "GetPlanetariumChance");
    lua_pushcfunction(g_L, Level_GetCurrentRoomDesc); lua_setfield(g_L, -2, "GetCurrentRoomDesc");
    lua_pushcfunction(g_L, Level_GetLastRoomDesc); lua_setfield(g_L, -2, "GetLastRoomDesc");
    lua_pushcfunction(g_L, Level_GetRoomByIdx); lua_setfield(g_L, -2, "GetRoomByIdx");
    lua_pushcfunction(g_L, Level_GetRooms); lua_setfield(g_L, -2, "GetRooms");
    lua_pushcfunction(g_L, Level_GetCurrentRoom); lua_setfield(g_L, -2, "GetCurrentRoom");
    lua_pushcfunction(g_L, Level_GetStartingRoomIndex); lua_setfield(g_L, -2, "GetStartingRoomIndex");
    lua_pushcfunction(g_L, Level_GetAbsoluteStage); lua_setfield(g_L, -2, "GetAbsoluteStage");
    lua_pushcfunction(g_L, Level_IsAscent); lua_setfield(g_L, -2, "IsAscent");
    lua_pushcfunction(g_L, Level_IsPreAscent); lua_setfield(g_L, -2, "IsPreAscent");
    lua_pushcfunction(g_L, Level_UncoverHiddenDoor); lua_setfield(g_L, -2, "UncoverHiddenDoor");
    lua_pushcfunction(g_L, Level_MakeRedRoomDoor); lua_setfield(g_L, -2, "MakeRedRoomDoor");
    lua_pushvalue(g_L, -1); lua_setfield(g_L, -2, "__index");
    lua_pop(g_L, 1);

    // Create Isaac Global Table
    lua_newtable(g_L);
    lua_pushcfunction(g_L, Isaac_DebugString); lua_setfield(g_L, -2, "DebugString");
    lua_pushcfunction(g_L, Isaac_ConsoleOutput); lua_setfield(g_L, -2, "ConsoleOutput");
    lua_pushcfunction(g_L, Isaac_GetPlayer); lua_setfield(g_L, -2, "GetPlayer");
    lua_pushcfunction(g_L, Isaac_GetRoom); lua_setfield(g_L, -2, "GetRoom");
    lua_pushcfunction(g_L, Isaac_GetGame); lua_setfield(g_L, -2, "GetGame");
    lua_pushcfunction(g_L, Isaac_Spawn); lua_setfield(g_L, -2, "Spawn");
    lua_pushcfunction(g_L, Isaac_FindByType); lua_setfield(g_L, -2, "FindByType");
    lua_pushcfunction(g_L, Isaac_CountEntities); lua_setfield(g_L, -2, "CountEntities");
    lua_pushcfunction(g_L, Isaac_CountBosses); lua_setfield(g_L, -2, "CountBosses");
    lua_pushcfunction(g_L, Isaac_CountEnemies); lua_setfield(g_L, -2, "CountEnemies");
    lua_pushcfunction(g_L, Isaac_GetRoomEntities); lua_setfield(g_L, -2, "GetRoomEntities");
    lua_pushcfunction(g_L, Isaac_FindInRadius); lua_setfield(g_L, -2, "FindInRadius");
    lua_pushcfunction(g_L, Isaac_GetChallenge); lua_setfield(g_L, -2, "GetChallenge");
    lua_pushcfunction(g_L, Isaac_RenderText); lua_setfield(g_L, -2, "RenderText");
    lua_pushcfunction(g_L, Isaac_RenderScaledText); lua_setfield(g_L, -2, "RenderScaledText");
    lua_pushcfunction(g_L, Isaac_WorldToScreen); lua_setfield(g_L, -2, "WorldToScreen");
    lua_pushcfunction(g_L, Isaac_ScreenToWorld); lua_setfield(g_L, -2, "ScreenToWorld");
    lua_pushcfunction(g_L, Isaac_WorldToRenderPosition); lua_setfield(g_L, -2, "WorldToRenderPosition");
    lua_pushcfunction(g_L, Isaac_ScreenToWorldDistance); lua_setfield(g_L, -2, "ScreenToWorldDistance");
    lua_pushcfunction(g_L, Isaac_Explode); lua_setfield(g_L, -2, "Explode");
    lua_pushcfunction(g_L, Isaac_GridSpawn); lua_setfield(g_L, -2, "GridSpawn");
    lua_pushcfunction(g_L, Isaac_ExecuteCommand); lua_setfield(g_L, -2, "ExecuteCommand");
    lua_pushcfunction(g_L, Isaac_GetItemIdByName); lua_setfield(g_L, -2, "GetItemIdByName");
    lua_pushcfunction(g_L, Isaac_GetTrinketIdByName); lua_setfield(g_L, -2, "GetTrinketIdByName");
    lua_pushcfunction(g_L, Isaac_GetCardIdByName); lua_setfield(g_L, -2, "GetCardIdByName");
    lua_pushcfunction(g_L, Isaac_GetPillEffectIdByName); lua_setfield(g_L, -2, "GetPillEffectIdByName");
    lua_pushcfunction(g_L, Isaac_GetSoundIdByName); lua_setfield(g_L, -2, "GetSoundIdByName");
    lua_pushcfunction(g_L, Isaac_GetMusicIdByName); lua_setfield(g_L, -2, "GetMusicIdByName");
    lua_pushcfunction(g_L, Isaac_GetEntityVariantByName); lua_setfield(g_L, -2, "GetEntityVariantByName");
    lua_pushcfunction(g_L, Isaac_GetEntityTypeByName); lua_setfield(g_L, -2, "GetEntityTypeByName");
    lua_pushcfunction(g_L, Isaac_GetPlayerTypeByName); lua_setfield(g_L, -2, "GetPlayerTypeByName");
    lua_pushcfunction(g_L, Isaac_GetCostumeIdByName); lua_setfield(g_L, -2, "GetCostumeIdByName");
    lua_pushcfunction(g_L, Isaac_GetTime); lua_setfield(g_L, -2, "GetTime");
    lua_pushcfunction(g_L, Isaac_IsInGame); lua_setfield(g_L, -2, "IsInGame");
    lua_pushcfunction(g_L, Isaac_GetFrameCount); lua_setfield(g_L, -2, "GetFrameCount");
    lua_pushcfunction(g_L, Isaac_GetItemConfig); lua_setfield(g_L, -2, "GetItemConfig");
    lua_pushcfunction(g_L, Isaac_SaveModData); lua_setfield(g_L, -2, "SaveModData");
    lua_pushcfunction(g_L, Isaac_LoadModData); lua_setfield(g_L, -2, "LoadModData");
    lua_pushcfunction(g_L, Isaac_HasModData); lua_setfield(g_L, -2, "HasModData");
    lua_pushcfunction(g_L, Isaac_GetPersistentGameData); lua_setfield(g_L, -2, "GetPersistentGameData");
    lua_pushcfunction(g_L, Isaac_GetCallbacks); lua_setfield(g_L, -2, "GetCallbacks");
    lua_pushcfunction(g_L, Isaac_RunCallback); lua_setfield(g_L, -2, "RunCallback");
    lua_pushcfunction(g_L, RegisterMod_fn); lua_setfield(g_L, -2, "RegisterMod");
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
    lua_pushinteger(g_L, 100); lua_setfield(g_L, -2, "MC_HUD_RENDER");
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
        const char *msg = nullptr;
        if (lua_istable(g_L, -1)) {
            lua_getfield(g_L, -1, "message");
            if (lua_isstring(g_L, -1)) msg = lua_tostring(g_L, -1);
            lua_pop(g_L, 1);
        }
        if (!msg) {
            msg = luaL_tolstring(g_L, -1, nullptr);
            lua_pop(g_L, 1);
        }
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
        const char *msg = nullptr;
        if (lua_istable(g_L, -1)) {
            lua_getfield(g_L, -1, "message");
            if (lua_isstring(g_L, -1)) msg = lua_tostring(g_L, -1);
            lua_pop(g_L, 1);
        }
        if (!msg) {
            msg = luaL_tolstring(g_L, -1, nullptr);
            lua_pop(g_L, 1);
        }
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

        // Pass mod reference (self) as the FIRST argument
        lua_rawgeti(g_L, LUA_REGISTRYINDEX, entry.modRef);
        int argCount = 1;

        if (pushArgs) {
            int topBefore = lua_gettop(g_L);
            pushArgs(g_L);
            argCount += (lua_gettop(g_L) - topBefore);
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
    DispatchCallback(2, nullptr);   // MC_POST_RENDER (2)
    DispatchCallback(100, nullptr); // MC_HUD_RENDER (100)
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
