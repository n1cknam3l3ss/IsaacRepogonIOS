#import "RepogonOverlay.h"
#import "RepogonEngine.h"
#import "RepogonLogger.h"

void RepogonOverlayInit(void) {
    RepogonLog(@"[Overlay] UIKit overlay deprecated in favor of native in-game KAGE engine rendering.");
}

void RepogonOverlayAddText(NSString *text, float x, float y, float r, float g, float b, float a) {
    if (!text || text.length == 0) return;
    RepogonRenderTextNative(text.UTF8String, x, y, r, g, b, a);
}

void RepogonOverlayAddScaledText(NSString *text, float x, float y, float sx, float sy, float r, float g, float b, float a) {
    if (!text || text.length == 0) return;
    RepogonRenderScaledTextNative(text.UTF8String, x, y, sx, sy, r, g, b, a, 0);
}

void RepogonOverlayClear(void) {
}

void RepogonOverlayFlush(void) {
}
