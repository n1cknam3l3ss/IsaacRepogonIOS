#import "RepogonModManager.h"
#import "RepogonLua.h"
#import "RepogonLogger.h"
#import "RepogonVFS.h"
#import "RepogonXMLMerger.h"

extern "C" {
#include "lua.h"
#include "lauxlib.h"
}

#include <vector>
#include <string>

static NSString *g_modsDirectory = nil;

NSString *RepogonGetModsDirectory(void) {
    if (!g_modsDirectory) {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docDir = paths.firstObject;
        g_modsDirectory = [docDir stringByAppendingPathComponent:@"mods"];
    }
    return g_modsDirectory;
}

static void CreateSampleModIfNeeded(NSString *modsDir) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *sampleDir = [modsDir stringByAppendingPathComponent:@"RepogonTest"];
    NSString *sampleMain = [sampleDir stringByAppendingPathComponent:@"main.lua"];

    if (![fm fileExistsAtPath:sampleMain]) {
        [fm createDirectoryAtPath:sampleDir withIntermediateDirectories:YES attributes:nil error:nil];

        NSString *sampleCode =
            @"-- Repogon iOS Starter Mod\n"
            @"local mod = RegisterMod(\"RepogonTest\", 1)\n\n"
            @"Isaac.DebugString(\"=== [RepogonTest] Loaded Successfully on iOS! ===\")\n\n"
            @"local tick = 0\n"
            @"function mod:OnUpdate()\n"
            @"    tick = tick + 1\n"
            @"    if tick % 180 == 0 then\n"
            @"        local player = Isaac.GetPlayer(0)\n"
            @"        local hearts = player and player:GetHearts() or 0\n"
            @"        local coins = player and player:GetNumCoins() or 0\n"
            @"        Isaac.DebugString(string.format(\"[RepogonTest] Tick: %d | Hearts: %d, Coins: %d\", tick, hearts, coins))\n"
            @"    end\n"
            @"end\n\n"
            @"function mod:OnRender()\n"
            @"    Isaac.RenderText(\"REPENTOGON iOS Active\", 40, 20, 0.2, 1.0, 0.4, 0.9)\n"
            @"end\n\n"
            @"mod:AddCallback(ModCallbacks.MC_POST_UPDATE, mod.OnUpdate)\n"
            @"mod:AddCallback(ModCallbacks.MC_POST_RENDER, mod.OnRender)\n";

        [sampleCode writeToFile:sampleMain atomically:YES encoding:NSUTF8StringEncoding error:nil];
        RepogonLog(@"Created sample mod at: %@", sampleMain);
    }
}

void RepogonModManagerInit(void) {
    NSString *modsDir = RepogonGetModsDirectory();
    NSFileManager *fm = [NSFileManager defaultManager];

    BOOL isDir = NO;
    if (![fm fileExistsAtPath:modsDir isDirectory:&isDir] || !isDir) {
        [fm createDirectoryAtPath:modsDir withIntermediateDirectories:YES attributes:nil error:nil];
        RepogonLog(@"Created mods directory at: %@", modsDir);
    }

    CreateSampleModIfNeeded(modsDir);
}

void RepogonModManagerScanAssetsAndMergeXML(void) {
    NSString *modsDir = RepogonGetModsDirectory();
    NSFileManager *fm = [NSFileManager defaultManager];

    NSError *err = nil;
    NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:modsDir error:&err];
    if (err || !items) {
        RepogonLog(@"Failed to list mods directory: %@", err.localizedDescription);
        return;
    }

    items = [items sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    RepogonLog(@"Discovered %lu items in %@", (unsigned long)items.count, modsDir);

    std::vector<std::string> validModDirs;
    for (NSString *item in items) {
        NSString *modPath = [modsDir stringByAppendingPathComponent:item];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:modPath isDirectory:&isDir] && isDir) {
            validModDirs.push_back([modPath UTF8String]);
        }
    }

    // 1. Register with Virtual File System for asset redirection
    RepogonVFSClearModDirectories();
    for (const auto &d : validModDirs) {
        RepogonVFSAddModDirectory(d.c_str());
    }

    // 2. Perform dynamic XML merging (players.xml, items.xml, etc.)
    RepogonXMLMergerProcessMods(validModDirs);
}

void RepogonModManagerScanAndLoadMods(void) {
    RepogonModManagerScanAssetsAndMergeXML();

    NSString *modsDir = RepogonGetModsDirectory();
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:modsDir error:nil];
    if (!items) return;
    items = [items sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];

    // 3. Load Lua scripts
    lua_State *L = RepogonLuaGetState();

    for (NSString *item in items) {
        NSString *modPath = [modsDir stringByAppendingPathComponent:item];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:modPath isDirectory:&isDir] || !isDir) continue;

        NSString *mainLuaPath = [modPath stringByAppendingPathComponent:@"main.lua"];
        if (![fm fileExistsAtPath:mainLuaPath]) {
            continue;
        }

        // Auto-patch PlanetariumChance to prevent it disabling itself under iOS REPENTOGON
        if ([item isEqualToString:@"PlanetariumChance"] || [mainLuaPath containsString:@"PlanetariumChance"]) {
            NSString *src = [NSString stringWithContentsOfFile:mainLuaPath encoding:NSUTF8StringEncoding error:nil];
            if (src && [src containsString:@"self.storage.repentogonEnabled = true"]) {
                src = [src stringByReplacingOccurrencesOfString:@"self.storage.repentogonEnabled = true"
                                                     withString:@"self.storage.repentogonEnabled = false -- auto-patched for iOS"];
                [src writeToFile:mainLuaPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
                RepogonLog(@"Auto-patched PlanetariumChance to remain enabled under iOS REPENTOGON.");
            }
        }

        RepogonLog(@"Loading mod [%@] from: %@", item, mainLuaPath);

        // Update package.path for this mod
        if (L) {
            NSString *pkgScript = [NSString stringWithFormat:
                @"package.path = package.path .. ';%@/?.lua;%@/?/init.lua'",
                modPath, modPath];
            RepogonLuaRunString([pkgScript UTF8String]);
        }

        // Execute main.lua
        bool ok = RepogonLuaRunFile([mainLuaPath UTF8String]);
        if (ok) {
            RepogonLog(@"Successfully loaded mod [%@].", item);
        } else {
            RepogonLog(@"Failed to load mod [%@]. Check error log above.", item);
        }
    }
}
