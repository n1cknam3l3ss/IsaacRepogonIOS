#import "RepogonEngine.h"
#import "RepogonMemory.h"
#import "RepogonLogger.h"
#import "RepogonLua.h"

#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <objc/runtime.h>

namespace {

constexpr const char *kSupportedUUID = "F4357753-A25F-30EE-BACF-63709F902895";

constexpr uintptr_t kGameGlobalRVA = 0xAC3B90;
constexpr size_t kGameCurrentRoomOffset = 0x21550;
constexpr size_t kGameFrameCountOffset = 0x1CF42C;

constexpr uintptr_t kManagerGlobalRVA = 0xAC2428;
constexpr size_t kManagerFontMPlus12Offset = 0x600;
constexpr size_t kManagerFontMPlus10Offset = 0x20650;
constexpr size_t kManagerFontTempestaOffset = 0x80740;
constexpr size_t kManagerFontUpheavalOffset = 0xa0790;
constexpr size_t kManagerFontTeamMeatOffset = 0xc07e0;

constexpr uintptr_t kFontGetStringWidthRVA = 0x8BDEC4;
constexpr uintptr_t kFontDrawStringRVA = 0x8BE324;
constexpr uintptr_t kFontDrawStringScaledRVA = 0x8BE0C4;

constexpr size_t kRoomDescriptorOffset = 0x8;
constexpr size_t kRoomDescriptorDataOffset = 0x10;
constexpr size_t kRoomConfigTypeOffset = 0x8;
constexpr size_t kRoomEntitiesArrayOffset = 0x19C8;
constexpr size_t kRoomEntitiesCountOffset = 0x19D4;
constexpr size_t kRoomClearOffset = 0x19E0;

constexpr uintptr_t kRoomGetCenterPosRVA = 0x59E2AC;
constexpr uintptr_t kRoomGetGridIndexRVA = 0x5A18AC;
constexpr uintptr_t kRoomFindFreeTileRVA = 0x5AB878;
constexpr uintptr_t kGameSpawnEntityRVA = 0x88FCBC;

typedef Vector2f (*GetCenterPos_t)(void *room);
typedef int32_t (*GetGridIndex_t)(void *room, const Vector2f *pos);
typedef void* (*GameSpawn_t)(void *game, int32_t type, int32_t variant, const Vector2f *pos, const Vector2f *velocity, void *spawner, int32_t subType, uint32_t seed);
typedef int32_t (*FontGetStringWidth_t)(void *font, const char *str);
typedef void (*FontDrawString_t)(void *font, const char *str, float x, float y, const KColor *color, int32_t boxWidth, bool center);
typedef void (*FontDrawStringScaled_t)(void *font, const char *str, float x, float y, float scaleX, float scaleY, const KColor *color, int32_t boxWidth, bool center);

static NSString *UUIDForHeader(const mach_header_64 *header) {
    if (!header || header->magic != MH_MAGIC_64) return @"";
    const uint8_t *cursor = reinterpret_cast<const uint8_t *>(header + 1);
    for (uint32_t i = 0; i < header->ncmds; ++i) {
        const load_command *cmd = reinterpret_cast<const load_command *>(cursor);
        if (cmd->cmd == LC_UUID && cmd->cmdsize >= sizeof(uuid_command)) {
            const uuid_command *ucmd = reinterpret_cast<const uuid_command *>(cursor);
            const unsigned char *u = ucmd->uuid;
            return [NSString stringWithFormat:
                    @"%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
                    u[0],u[1],u[2],u[3],u[4],u[5],u[6],u[7],u[8],u[9],u[10],u[11],u[12],u[13],u[14],u[15]];
        }
        cursor += cmd->cmdsize;
    }
    return @"";
}

static const mach_header_64 *FindIsaacHeader(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; ++i) {
        const mach_header_64 *header = reinterpret_cast<const mach_header_64 *>(_dyld_get_image_header(i));
        NSString *uuid = UUIDForHeader(header);
        if ([uuid caseInsensitiveCompare:[NSString stringWithUTF8String:kSupportedUUID]] == NSOrderedSame) {
            return header;
        }
    }
    for (uint32_t i = 0; i < count; ++i) {
        const mach_header_64 *header = reinterpret_cast<const mach_header_64 *>(_dyld_get_image_header(i));
        if (header && header->magic == MH_MAGIC_64 && header->filetype == MH_EXECUTE) {
            return header;
        }
    }
    return nullptr;
}

} // namespace

uintptr_t RepogonGetBaseAddress(void) {
    const mach_header_64 *header = FindIsaacHeader();
    return reinterpret_cast<uintptr_t>(header);
}

bool RepogonIsSupportedBuild(uintptr_t *outBase) {
    const mach_header_64 *header = FindIsaacHeader();
    if (!header) return false;
    NSString *uuid = UUIDForHeader(header);
    bool match = ([uuid caseInsensitiveCompare:[NSString stringWithUTF8String:kSupportedUUID]] == NSOrderedSame);
    if (match && outBase) *outBase = reinterpret_cast<uintptr_t>(header);
    return match;
}

uintptr_t RepogonGetGame(void) {
    uintptr_t base = RepogonGetBaseAddress();
    if (!base) return 0;
    uintptr_t game = 0;
    SafeRead(base + kGameGlobalRVA, game);
    return game;
}

uintptr_t RepogonGetRoom(void) {
    uintptr_t game = RepogonGetGame();
    if (!game) return 0;
    uintptr_t room = 0;
    SafeRead(game + kGameCurrentRoomOffset, room);
    return room;
}

size_t RepogonGetEntityCount(void) {
    uintptr_t room = RepogonGetRoom();
    if (!room) return 0;
    int32_t count = 0;
    if (SafeRead(room + kRoomEntitiesCountOffset, count) && count > 0 && count < 4096) {
        return static_cast<size_t>(count);
    }
    return 0;
}

uintptr_t RepogonGetEntityAtIndex(size_t index) {
    uintptr_t room = RepogonGetRoom();
    if (!room) return 0;
    uintptr_t arr = 0;
    if (!SafeRead(room + kRoomEntitiesArrayOffset, arr) || !arr) return 0;
    uintptr_t ent = 0;
    SafeRead(arr + index * sizeof(uintptr_t), ent);
    return ent;
}

static uintptr_t s_cachedPlayer0 = 0;

uintptr_t RepogonGetPlayer(int index) {
    size_t count = RepogonGetEntityCount();
    int curIdx = 0;
    for (size_t i = 0; i < count; ++i) {
        uintptr_t ent = RepogonGetEntityAtIndex(i);
        if (!ent) continue;
        if (RepogonEntityGetType(ent) == 1) { // Type 1 = Player
            if (curIdx == index) {
                if (index == 0) s_cachedPlayer0 = ent;
                return ent;
            }
            curIdx++;
        }
    }
    if (index == 0 && s_cachedPlayer0 != 0) {
        return s_cachedPlayer0;
    }
    return 0;
}

std::vector<uintptr_t> RepogonFindEntities(int type, int variant, int subType) {
    std::vector<uintptr_t> res;
    uintptr_t room = RepogonGetRoom();
    if (!room) return res;
    uintptr_t arr = 0;
    if (!SafeRead(room + kRoomEntitiesArrayOffset, arr) || !arr) return res;
    int32_t count = 0;
    if (!SafeRead(room + kRoomEntitiesCountOffset, count) || count <= 0 || count >= 4096) return res;

    for (int32_t i = 0; i < count; ++i) {
        uintptr_t ent = 0;
        SafeRead(arr + i * sizeof(uintptr_t), ent);
        if (!ent) continue;
        if (type >= 0 && RepogonEntityGetType(ent) != type) continue;
        if (variant >= 0 && RepogonEntityGetVariant(ent) != variant) continue;
        if (subType >= 0 && RepogonEntityGetSubType(ent) != subType) continue;
        res.push_back(ent);
    }
    return res;
}

int32_t RepogonEntityGetType(uintptr_t ent) {
    int32_t v = 0;
    SafeRead(ent + 0x38, v);
    return v;
}

int32_t RepogonEntityGetVariant(uintptr_t ent) {
    int32_t v = 0;
    SafeRead(ent + 0x3C, v);
    return v;
}

int32_t RepogonEntityGetSubType(uintptr_t ent) {
    int32_t v = 0;
    SafeRead(ent + 0x40, v);
    return v;
}

Vector2f RepogonEntityGetPosition(uintptr_t ent) {
    Vector2f v = {0.0f, 0.0f};
    SafeRead(ent + 0x48, v);
    return v;
}

void RepogonEntitySetPosition(uintptr_t ent, Vector2f pos) {
    SafeWrite(ent + 0x48, pos);
}

Vector2f RepogonEntityGetVelocity(uintptr_t ent) {
    Vector2f v = {0.0f, 0.0f};
    SafeRead(ent + 0x50, v);
    return v;
}

void RepogonEntitySetVelocity(uintptr_t ent, Vector2f vel) {
    SafeWrite(ent + 0x50, vel);
}

float RepogonEntityGetHP(uintptr_t ent) {
    float hp = 0.0f;
    SafeRead(ent + 0x354, hp);
    return hp;
}

void RepogonEntitySetHP(uintptr_t ent, float hp) {
    SafeWrite(ent + 0x354, hp);
}

float RepogonEntityGetMaxHP(uintptr_t ent) {
    float hp = 0.0f;
    SafeRead(ent + 0x358, hp);
    return hp;
}

void RepogonEntitySetMaxHP(uintptr_t ent, float maxHp) {
    SafeWrite(ent + 0x358, maxHp);
}

uint64_t RepogonEntityGetFlags(uintptr_t ent) {
    uint64_t f = 0;
    SafeRead(ent + 0x1B8, f);
    return f;
}

void RepogonEntitySetFlags(uintptr_t ent, uint64_t flags) {
    SafeWrite(ent + 0x1B8, flags);
}

bool RepogonEntityIsDead(uintptr_t ent) {
    uint8_t d = 0;
    SafeRead(ent + 0x1C3, d);
    return d != 0;
}

void RepogonEntityKill(uintptr_t ent) {
    uint8_t d = 1;
    SafeWrite(ent + 0x1C3, d);
    float zero = 0.0f;
    SafeWrite(ent + 0x354, zero);
}

// Player Properties
int32_t RepogonPlayerGetHearts(uintptr_t player) {
    int32_t val = 0;
    SafeRead(player + 0x1270, val);
    return val;
}

void RepogonPlayerSetHearts(uintptr_t player, int32_t hearts) {
    SafeWrite(player + 0x1270, hearts);
}

int32_t RepogonPlayerGetMaxHearts(uintptr_t player) {
    int32_t val = 0;
    SafeRead(player + 0x1274, val);
    return val;
}

void RepogonPlayerSetMaxHearts(uintptr_t player, int32_t hearts) {
    SafeWrite(player + 0x1274, hearts);
}

int32_t RepogonPlayerGetSoulHearts(uintptr_t player) {
    int32_t val = 0;
    SafeRead(player + 0x1278, val);
    return val;
}

void RepogonPlayerSetSoulHearts(uintptr_t player, int32_t hearts) {
    SafeWrite(player + 0x1278, hearts);
}

int32_t RepogonPlayerGetBlackHearts(uintptr_t player) {
    int32_t val = 0;
    SafeRead(player + 0x127C, val);
    return val;
}

void RepogonPlayerSetBlackHearts(uintptr_t player, int32_t hearts) {
    SafeWrite(player + 0x127C, hearts);
}

int32_t RepogonPlayerGetBoneHearts(uintptr_t player) {
    int32_t val = 0;
    SafeRead(player + 0x1280, val);
    return val;
}

void RepogonPlayerSetBoneHearts(uintptr_t player, int32_t hearts) {
    SafeWrite(player + 0x1280, hearts);
}

int32_t RepogonPlayerGetCoins(uintptr_t player) {
    int32_t val = 0;
    SafeRead(player + 0x128C, val);
    return val;
}

void RepogonPlayerAddCoins(uintptr_t player, int32_t coins) {
    int32_t cur = RepogonPlayerGetCoins(player);
    SafeWrite(player + 0x128C, cur + coins);
}

int32_t RepogonPlayerGetBombs(uintptr_t player) {
    int32_t val = 0;
    SafeRead(player + 0x1290, val);
    return val;
}

void RepogonPlayerAddBombs(uintptr_t player, int32_t bombs) {
    int32_t cur = RepogonPlayerGetBombs(player);
    SafeWrite(player + 0x1290, cur + bombs);
}

int32_t RepogonPlayerGetKeys(uintptr_t player) {
    int32_t val = 0;
    SafeRead(player + 0x1294, val);
    return val;
}

void RepogonPlayerAddKeys(uintptr_t player, int32_t keys) {
    int32_t cur = RepogonPlayerGetKeys(player);
    SafeWrite(player + 0x1294, cur + keys);
}

float RepogonPlayerGetDamage(uintptr_t player) {
    float dmg = 0.0f;
    SafeRead(player + 0x129C, dmg);
    return dmg;
}

void RepogonPlayerSetDamage(uintptr_t player, float dmg) {
    SafeWrite(player + 0x129C, dmg);
}

float RepogonPlayerGetMoveSpeed(uintptr_t player) {
    float spd = 0.0f;
    SafeRead(player + 0x1298, spd);
    return spd;
}

void RepogonPlayerSetMoveSpeed(uintptr_t player, float spd) {
    SafeWrite(player + 0x1298, spd);
}

int32_t RepogonPlayerGetActiveItem(uintptr_t player, int slot) {
    int32_t itm = 0;
    SafeRead(player + 0x12B0 + slot * 8, itm);
    return itm;
}

int32_t RepogonPlayerGetActiveCharge(uintptr_t player, int slot) {
    int32_t chg = 0;
    SafeRead(player + 0x12B4 + slot * 8, chg);
    return chg;
}

void RepogonPlayerSetActiveCharge(uintptr_t player, int charge, int slot) {
    SafeWrite(player + 0x12B4 + slot * 8, charge);
}

int32_t RepogonPlayerGetType(uintptr_t player) {
    int32_t t = 0;
    SafeRead(player + 0x12C0, t);
    return t;
}

// Room Properties
int32_t RepogonRoomGetType(void) {
    uintptr_t room = RepogonGetRoom();
    if (!room) return 0;
    uintptr_t descriptor = 0;
    if (SafeRead(room + kRoomDescriptorOffset, descriptor) && descriptor) {
        uintptr_t roomData = 0;
        if (SafeRead(descriptor + kRoomDescriptorDataOffset, roomData) && roomData) {
            int32_t type = 0;
            SafeRead(roomData + kRoomConfigTypeOffset, type);
            return type;
        }
    }
    return 0;
}

Vector2f RepogonRoomGetCenterPos(void) {
    uintptr_t base = RepogonGetBaseAddress();
    uintptr_t room = RepogonGetRoom();
    if (!base || !room) return {0.0f, 0.0f};
    GetCenterPos_t getCenter = reinterpret_cast<GetCenterPos_t>(base + kRoomGetCenterPosRVA);
    return getCenter(reinterpret_cast<void *>(room));
}

int32_t RepogonRoomGetGridIndex(Vector2f pos) {
    uintptr_t base = RepogonGetBaseAddress();
    uintptr_t room = RepogonGetRoom();
    if (!base || !room) return -1;
    GetGridIndex_t getIndex = reinterpret_cast<GetGridIndex_t>(base + kRoomGetGridIndexRVA);
    return getIndex(reinterpret_cast<void *>(room), &pos);
}

bool RepogonRoomIsClear(void) {
    uintptr_t room = RepogonGetRoom();
    if (!room) return false;
    uint8_t c = 0;
    SafeRead(room + kRoomClearOffset, c);
    return c != 0;
}

// Game Actions
uintptr_t RepogonGameSpawn(int type, int variant, Vector2f pos, Vector2f vel, uintptr_t spawner, int subType, uint32_t seed) {
    uintptr_t base = RepogonGetBaseAddress();
    uintptr_t game = RepogonGetGame();
    if (!base || !game) return 0;
    GameSpawn_t spawn = reinterpret_cast<GameSpawn_t>(base + kGameSpawnEntityRVA);
    void *ent = spawn(reinterpret_cast<void *>(game), type, variant, &pos, &vel, reinterpret_cast<void *>(spawner), subType, seed);
    return reinterpret_cast<uintptr_t>(ent);
}

int32_t RepogonGameGetStage(void) {
    uintptr_t game = RepogonGetGame();
    if (!game) return 0;
    int32_t stage = 0;
    SafeRead(game + 0x0, stage);
    return stage;
}

int32_t RepogonGameGetStageType(void) {
    uintptr_t game = RepogonGetGame();
    if (!game) return 0;
    int32_t stageType = 0;
    SafeRead(game + 0x4, stageType);
    return stageType;
}

uint32_t RepogonGameGetFrameCount(void) {
    uintptr_t game = RepogonGetGame();
    if (!game) return 0;
    uint32_t fc = 0;
    SafeRead(game + kGameFrameCountOffset, fc);
    return fc;
}

// Native KAGE Font & Rendering

uintptr_t RepogonGetManager(void) {
    uintptr_t base = RepogonGetBaseAddress();
    if (!base) return 0;
    uintptr_t mgr = 0;
    SafeRead(base + kManagerGlobalRVA, mgr);
    return mgr;
}

uintptr_t RepogonGetDefaultFont(void) {
    return RepogonGetFontByType(0);
}

uintptr_t RepogonGetFontByType(int type) {
    uintptr_t mgr = RepogonGetManager();
    if (!mgr) return 0;
    switch (type) {
        case 1: return mgr + kManagerFontUpheavalOffset;
        case 2: return mgr + kManagerFontTeamMeatOffset;
        case 3: return mgr + kManagerFontMPlus12Offset;
        case 4: return mgr + kManagerFontMPlus10Offset;
        case 0:
        default: return mgr + kManagerFontTempestaOffset;
    }
}

bool RepogonRenderTextNative(const char *text, float x, float y, float r, float g, float b, float a) {
    if (!text || !*text) return false;
    uintptr_t base = RepogonGetBaseAddress();
    if (!base) return false;
    uintptr_t font = RepogonGetDefaultFont();
    if (!font) return false;

    auto drawFunc = reinterpret_cast<FontDrawString_t>(base + kFontDrawStringRVA);
    KColor color = { r, g, b, a };
    drawFunc(reinterpret_cast<void *>(font), text, x, y, &color, 0, false);
    return true;
}

bool RepogonRenderScaledTextNative(const char *text, float x, float y, float sx, float sy, float r, float g, float b, float a, int fontType) {
    if (!text || !*text) return false;
    uintptr_t base = RepogonGetBaseAddress();
    if (!base) return false;
    uintptr_t font = RepogonGetFontByType(fontType);
    if (!font) font = RepogonGetDefaultFont();
    if (!font) return false;

    auto drawFunc = reinterpret_cast<FontDrawStringScaled_t>(base + kFontDrawStringScaledRVA);
    KColor color = { r, g, b, a };
    drawFunc(reinterpret_cast<void *>(font), text, x, y, sx, sy, &color, 0, false);
    return true;
}

int32_t RepogonGetStringWidthNative(const char *text, int fontType) {
    if (!text || !*text) return 0;
    uintptr_t base = RepogonGetBaseAddress();
    if (!base) return 0;
    uintptr_t font = RepogonGetFontByType(fontType);
    if (!font) font = RepogonGetDefaultFont();
    if (!font) return 0;

    auto widthFunc = reinterpret_cast<FontGetStringWidth_t>(base + kFontGetStringWidthRVA);
    return widthFunc(reinterpret_cast<void *>(font), text);
}

// Render Hook via -[IsaacShell draw:] Swizzling
static void (*g_orig_IsaacShell_draw)(id, SEL, BOOL) = nullptr;

static void RepogonHooked_IsaacShell_draw(id self, SEL _cmd, BOOL arg1) {
    if (g_orig_IsaacShell_draw) {
        g_orig_IsaacShell_draw(self, _cmd, arg1);
    }

    // Isaac frame render is complete and OpenGL ES framebuffer is active!
    // Dispatch Lua render callbacks (MC_POST_RENDER and MC_HUD_RENDER)
    @autoreleasepool {
        RepogonLuaDispatchRender();
    }
}

void RepogonRenderHookInit(void) {
    static bool s_hooked = false;
    if (s_hooked) return;

    Class cls = objc_getClass("IsaacShell");
    if (!cls) {
        return;
    }

    SEL sel = @selector(draw:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        return;
    }

    g_orig_IsaacShell_draw = reinterpret_cast<void (*)(id, SEL, BOOL)>(method_getImplementation(m));
    method_setImplementation(m, reinterpret_cast<IMP>(RepogonHooked_IsaacShell_draw));
    s_hooked = true;
    RepogonLog(@"[RenderHook] Successfully hooked -[IsaacShell draw:] -> Native in-game KAGE rendering active!");
}

