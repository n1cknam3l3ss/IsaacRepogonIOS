#import "RepogonOverlay.h"
#import "RepogonLogger.h"

#include <vector>
#include <mutex>

struct TextDrawCommand {
    NSString *text;
    float x;
    float y;
    float sx;
    float sy;
    float r;
    float g;
    float b;
    float a;
};

@interface RepogonOverlayView : UIView
@property (nonatomic, assign) std::vector<TextDrawCommand> commands;
@end

@implementation RepogonOverlayView

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    return nil; // Passthrough to game controls
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    for (const auto &cmd : self.commands) {
        if (!cmd.text || cmd.text.length == 0) continue;

        CGFloat fontSize = 12.0f * (cmd.sy > 0.0f ? cmd.sy : 1.0f);
        UIFont *font = [UIFont fontWithName:@"Courier-Bold" size:fontSize];
        if (!font) font = [UIFont monospacedSystemFontOfSize:fontSize weight:UIFontWeightBold];

        UIColor *color = [UIColor colorWithRed:cmd.r green:cmd.g blue:cmd.b alpha:cmd.a];
        NSDictionary *attrs = @{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: color
        };

        CGPoint pt = CGPointMake(cmd.x, cmd.y);
        [cmd.text drawAtPoint:pt withAttributes:attrs];
    }
}

@end

static RepogonOverlayView *g_overlayView = nil;
static std::vector<TextDrawCommand> g_pendingCommands;
static std::mutex g_overlayMutex;

void RepogonOverlayInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_overlayView) return;

        UIWindow *window = nil;
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            if (w.isKeyWindow) { window = w; break; }
        }
        if (!window) window = UIApplication.sharedApplication.windows.firstObject;

        if (window) {
            g_overlayView = [[RepogonOverlayView alloc] initWithFrame:window.bounds];
            g_overlayView.backgroundColor = [UIColor clearColor];
            g_overlayView.userInteractionEnabled = NO;
            g_overlayView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [window addSubview:g_overlayView];
            [window bringSubviewToFront:g_overlayView];
            RepogonLog(@"RepogonOverlayView initialized and attached to key window.");
        }
    });
}

void RepogonOverlayAddText(NSString *text, float x, float y, float r, float g, float b, float a) {
    RepogonOverlayAddScaledText(text, x, y, 1.0f, 1.0f, r, g, b, a);
}

void RepogonOverlayAddScaledText(NSString *text, float x, float y, float sx, float sy, float r, float g, float b, float a) {
    if (!text) return;
    std::lock_guard<std::mutex> lock(g_overlayMutex);
    TextDrawCommand cmd;
    cmd.text = [text copy];
    cmd.x = x;
    cmd.y = y;
    cmd.sx = sx;
    cmd.sy = sy;
    cmd.r = r;
    cmd.g = g;
    cmd.b = b;
    cmd.a = a;
    g_pendingCommands.push_back(cmd);
}

void RepogonOverlayClear(void) {
    std::lock_guard<std::mutex> lock(g_overlayMutex);
    g_pendingCommands.clear();
}

void RepogonOverlayFlush(void) {
    std::vector<TextDrawCommand> cmds;
    {
        std::lock_guard<std::mutex> lock(g_overlayMutex);
        cmds = g_pendingCommands;
        g_pendingCommands.clear();
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_overlayView) {
            RepogonOverlayInit();
        }
        if (g_overlayView) {
            g_overlayView.commands = cmds;
            [g_overlayView setNeedsDisplay];
        }
    });
}
