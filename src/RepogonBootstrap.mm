#import "RepogonBootstrap.h"
#import "RepogonEngine.h"
#import "RepogonLogger.h"
#import "RepogonLua.h"
#import "RepogonModManager.h"
#import "RepogonOverlay.h"
#import "RepogonVoidPatch.h"

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

void RepogonTick(void) {
    uintptr_t game = RepogonGetGame();
    if (!game) return;

    // Room transition detection
    uintptr_t room = RepogonGetRoom();
    if (room && room != g_lastRoom) {
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

    // Render pass
    RepogonLuaDispatchRender();

    // Guaranteed Void portal check
    RepogonVoidWatchdogTick();
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

        // 1. Initialize Screen Overlay
        RepogonOverlayInit();

        // 2. Initialize Lua 5.3 runtime
        if (!RepogonLuaInit()) {
            RepogonLog(@"Fatal: Failed to initialize Lua runtime.");
            return;
        }

        // 3. Initialize Mod Manager & discover mods in Documents/mods
        RepogonModManagerInit();
        RepogonModManagerScanAndLoadMods();

        // 4. Notify mods of game start
        RepogonLuaDispatchGameStarted(false);

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
                            usingBlock:^(__unused NSNotification *note) { RepogonStart(); }];

            if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
                RepogonStart();
            }
        });
    }
}
