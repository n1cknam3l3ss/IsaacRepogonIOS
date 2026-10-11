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

    bool isEqual(const TextDrawCommand &o) const {
        return fabsf(x - o.x) < 0.1f && fabsf(y - o.y) < 0.1f &&
               fabsf(sx - o.sx) < 0.01f && fabsf(sy - o.sy) < 0.01f &&
               fabsf(r - o.r) < 0.05f && fabsf(g - o.g) < 0.05f &&
               fabsf(b - o.b) < 0.05f && fabsf(a - o.a) < 0.05f &&
               (text == o.text || [text isEqualToString:o.text]);
    }
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

    CGFloat viewW = self.bounds.size.width;
    CGFloat viewH = self.bounds.size.height;
    if (viewW <= 0 || viewH <= 0) return;

    // Isaac's virtual resolution is 480 x 270 (16:9 aspect ratio)
    const CGFloat kVirtualW = 480.0f;
    const CGFloat kVirtualH = 270.0f;
    const CGFloat kTargetAspect = 16.0f / 9.0f;

    CGFloat currentAspect = viewW / viewH;
    CGFloat gameW = viewW;
    CGFloat gameH = viewH;
    CGFloat offsetX = 0.0f;
    CGFloat offsetY = 0.0f;

    if (currentAspect > kTargetAspect) {
        // Screen is wider than 16:9 (pillarbox black bars on left and right)
        gameH = viewH;
        gameW = gameH * kTargetAspect;
        offsetX = (viewW - gameW) * 0.5f;
    } else {
        // Screen is taller than 16:9 (letterbox black bars on top and bottom)
        gameW = viewW;
        gameH = gameW / kTargetAspect;
        offsetY = (viewH - gameH) * 0.5f;
    }

    CGFloat scale = gameH / kVirtualH;

    for (const auto &cmd : self.commands) {
        if (!cmd.text || cmd.text.length == 0) continue;

        // Map virtual Isaac (480x270) coordinates to screen viewport
        CGFloat screenX = offsetX + (cmd.x * scale);
        CGFloat screenY = offsetY + (cmd.y * scale);

        CGFloat fontScale = (cmd.sy > 0.0f ? cmd.sy : 1.0f);
        CGFloat fontSize = 8.0f * scale * fontScale;
        UIFont *font = [UIFont fontWithName:@"Courier-Bold" size:fontSize];
        if (!font) font = [UIFont monospacedSystemFontOfSize:fontSize weight:UIFontWeightBold];

        CGPoint pt = CGPointMake(screenX, screenY);

        // Subtle dark translucent rounded badge behind text for clean in-game HUD look
        CGSize textSize = [cmd.text sizeWithAttributes:@{ NSFontAttributeName: font }];
        CGRect bgRect = CGRectMake(pt.x - 2.0f, pt.y - 1.0f, textSize.width + 4.0f, textSize.height + 2.0f);
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:bgRect cornerRadius:3.0f];
        [[UIColor colorWithWhite:0.0f alpha:MIN(cmd.a * 0.65f, 0.75f)] setFill];
        [path fill];

        // 1px black outline / drop shadow for crisp readability
        UIColor *shadowColor = [UIColor colorWithWhite:0.0f alpha:MIN(cmd.a, 0.9f)];
        NSDictionary *shadowAttrs = @{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: shadowColor
        };
        [cmd.text drawAtPoint:CGPointMake(pt.x + 1.0f, pt.y + 1.0f) withAttributes:shadowAttrs];

        UIColor *color = [UIColor colorWithRed:cmd.r green:cmd.g blue:cmd.b alpha:cmd.a];
        NSDictionary *attrs = @{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: color
        };

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

    if (cmds.empty() && (!g_overlayView || g_overlayView.commands.empty())) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_overlayView) {
            RepogonOverlayInit();
        }
        if (g_overlayView) {
            // Check if commands are identical to existing view commands
            if (g_overlayView.commands.size() == cmds.size()) {
                bool identical = true;
                for (size_t i = 0; i < cmds.size(); ++i) {
                    if (!g_overlayView.commands[i].isEqual(cmds[i])) {
                        identical = false;
                        break;
                    }
                }
                if (identical) {
                    return; // 0% CPU! Commands unchanged, skip redraw
                }
            }
            g_overlayView.commands = std::move(cmds);
            [g_overlayView setNeedsDisplay];
        }
    });
}
