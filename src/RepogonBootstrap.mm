#import "RepogonBootstrap.h"
#import "RepogonEngine.h"
#import "RepogonLogger.h"
#import "RepogonLua.h"
#import "RepogonModManager.h"
#import "RepogonOverlay.h"
#import "RepogonVoidPatch.h"
#import "RepogonVFS.h"

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

static dispatch_once_t g_startOnce;
static CADisplayLink *g_displayLink = nil;
static uintptr_t g_lastRoom = 0;
static int32_t g_lastStage = -1;
static uint32_t g_lastFrameCount = 0;

@interface RepogonTickTarget : NSObject
- (void)onFrameTick:(CADisplayLink *)link;
@end

@implementation RepogonTickTarget
- (void)onFrameTick:(CADisplayLink *)link {
    @autoreleasepool {
        RepogonTick();
    }
}
@end

static RepogonTickTarget *g_tickTarget = nil;
static bool g_inRun = false;

static int g_noPlayerFrames = 0;

bool RepogonIsInRun(void) {
    return g_inRun;
}

void RepogonTick(void) {
    uintptr_t game = RepogonGetGame();
    if (!game) return;

    uintptr_t room = RepogonGetRoom();
    uintptr_t player0 = RepogonGetPlayer(0);

    // In-run game lifecycle detection
    if (player0 && room) {
        g_noPlayerFrames = 0;
        if (!g_inRun) {
            g_inRun = true;
            g_lastRoom = room;
            g_lastStage = RepogonGameGetStage();
            g_lastFrameCount = RepogonGameGetFrameCount();
            RepogonLuaDispatchGameStarted(false);
            RepogonLuaDispatchNewRoom();
            RepogonLuaDispatchNewLevel();
        }
    } else if (!room || !player0) {
        if (g_inRun) {
            g_noPlayerFrames++;
            if (g_noPlayerFrames > 90) { // 1.5s of consecutive null room/player
                g_inRun = false;
                RepogonLuaDispatchGameExit(true);
                g_lastRoom = 0;
                g_lastStage = -1;
            }
        }
    }

    if (g_inRun) {
        // Room transition detection
        if (room != g_lastRoom) {
            g_lastRoom = room;
            RepogonLuaDispatchNewRoom();
        }

        // Stage transition detection
        int32_t stage = RepogonGameGetStage();
        if (stage != g_lastStage) {
            g_lastStage = stage;
            RepogonLuaDispatchNewLevel();
        }

        // Game loop ticks
        uint32_t frameCount = RepogonGameGetFrameCount();
        if (frameCount != g_lastFrameCount) {
            g_lastFrameCount = frameCount;
            RepogonLuaDispatchUpdate();
        }

        // Guaranteed Void portal check
        RepogonVoidWatchdogTick();
    }

    // Always run render pass (flushes overlay view; MC_POST_RENDER runs on menu, MC_HUD_RENDER is guarded by g_inRun inside)
    RepogonLuaDispatchRender();
}

void RepogonStart(void) {
    dispatch_once(&g_startOnce, ^{
        uintptr_t base = 0;
        if (!RepogonIsSupportedBuild(&base)) {
            RepogonLog(@"Unsupported or non-Isaac executable image detected; skipping REPENTOGON initialization.");
            return;
        }

        RepogonLogInit();
        RepogonLog(@"==================================================");
        RepogonLog(@"Initializing Isaac REPENTOGON iOS (base: 0x%lx)", (unsigned long)base);
        RepogonLog(@"==================================================");

        // 1. Initialize Virtual File System & Asset Redirection
        RepogonVFSInit();

        // 2. Initialize Screen Overlay
        RepogonOverlayInit();

        // 3. Initialize Lua 5.3 runtime
        if (!RepogonLuaInit()) {
            RepogonLog(@"Fatal: Failed to initialize Lua runtime.");
            return;
        }

        // 4. Initialize Mod Manager & discover mods in Documents/mods
        RepogonModManagerInit();
        RepogonModManagerScanAndLoadMods();

        // 5. Setup display link for 60fps frame tick
        dispatch_async(dispatch_get_main_queue(), ^{
            g_tickTarget = [[RepogonTickTarget alloc] init];
            g_displayLink = [CADisplayLink displayLinkWithTarget:g_tickTarget selector:@selector(onFrameTick:)];
            [g_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
            RepogonLog(@"REPENTOGON iOS is fully active and running!");
        });
    });
}

__attribute__((constructor)) static void RepogonConstructor(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
            [center addObserverForName:UIApplicationDidBecomeActiveNotification
                                object:nil queue:NSOperationQueue.mainQueue
                            usingBlock:^(__unused NSNotification *note) {
                                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                    RepogonStart();
                                });
                            }];

            if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    RepogonStart();
                });
            }
        });
    }
}
