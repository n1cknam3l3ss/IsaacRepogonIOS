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
        return fabsf(x - o.x) < 0.5f && fabsf(y - o.y) < 0.5f &&
               fabsf(sx - o.sx) < 0.01f && fabsf(sy - o.sy) < 0.01f &&
               fabsf(r - o.r) < 0.05f && fabsf(g - o.g) < 0.05f &&
               fabsf(b - o.b) < 0.05f && fabsf(a - o.a) < 0.05f &&
               (text == o.text || [text isEqualToString:o.text]);
    }
};

@interface RepogonOverlayView : UIView
@property (nonatomic, strong) NSMutableArray<UILabel *> *labelPool;
@property (nonatomic, assign) std::vector<TextDrawCommand> commands;
- (void)updateCommands:(const std::vector<TextDrawCommand> &)cmds;
@end

@implementation RepogonOverlayView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _labelPool = [[NSMutableArray alloc] init];
    }
    return self;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    return nil; // Passthrough to game controls
}

- (void)updateCommands:(const std::vector<TextDrawCommand> &)cmds {
    if (self.commands.size() == cmds.size()) {
        bool identical = true;
        for (size_t i = 0; i < cmds.size(); ++i) {
            if (!self.commands[i].isEqual(cmds[i])) {
                identical = false;
                break;
            }
        }
        if (identical) {
            return; // 0% CPU overhead when overlay text is unchanged
        }
    }

    self.commands = cmds;

    CGFloat viewW = self.bounds.size.width;
    CGFloat viewH = self.bounds.size.height;
    if (viewW <= 0 || viewH <= 0) return;

    // Isaac's virtual resolution is 480 x 270 (16:9 aspect ratio)
    const CGFloat kVirtualH = 270.0f;
    const CGFloat kTargetAspect = 16.0f / 9.0f;

    CGFloat currentAspect = viewW / viewH;
    CGFloat gameW = viewW;
    CGFloat gameH = viewH;
    CGFloat offsetX = 0.0f;
    CGFloat offsetY = 0.0f;

    if (currentAspect > kTargetAspect) {
        gameH = viewH;
        gameW = gameH * kTargetAspect;
        offsetX = (viewW - gameW) * 0.5f;
    } else {
        gameW = viewW;
        gameH = gameW / kTargetAspect;
        offsetY = (viewH - gameH) * 0.5f;
    }

    CGFloat scale = gameH / kVirtualH;

    for (size_t i = 0; i < cmds.size(); ++i) {
        const auto &cmd = cmds[i];
        if (!cmd.text || cmd.text.length == 0) continue;

        UILabel *lbl = nil;
        if (i < self.labelPool.count) {
            lbl = self.labelPool[i];
        } else {
            lbl = [[UILabel alloc] init];
            lbl.userInteractionEnabled = NO;
            lbl.layer.masksToBounds = YES;
            lbl.layer.cornerRadius = 2.0f;
            lbl.textAlignment = NSTextAlignmentLeft;
            [self addSubview:lbl];
            [self.labelPool addObject:lbl];
        }

        CGFloat screenX = offsetX + (cmd.x * scale);
        CGFloat screenY = offsetY + (cmd.y * scale);

        // Compact font size: 5.2f gives clean ~8.3pt pixel font proportion on Retina display
        CGFloat fontScale = (cmd.sy > 0.0f ? cmd.sy : 1.0f);
        CGFloat fontSize = 5.2f * scale * fontScale;
        UIFont *font = [UIFont fontWithName:@"Courier-Bold" size:fontSize];
        if (!font) font = [UIFont monospacedSystemFontOfSize:fontSize weight:UIFontWeightBold];

        lbl.font = font;
        lbl.text = cmd.text;
        lbl.textColor = [UIColor colorWithRed:cmd.r green:cmd.g blue:cmd.b alpha:cmd.a];
        lbl.shadowColor = [UIColor colorWithWhite:0.0f alpha:MIN(cmd.a * 0.9f, 0.9f)];
        lbl.shadowOffset = CGSizeMake(1.0f, 1.0f);
        lbl.backgroundColor = [UIColor colorWithWhite:0.0f alpha:MIN(cmd.a * 0.65f, 0.75f)];

        CGSize textSize = [cmd.text sizeWithAttributes:@{ NSFontAttributeName: font }];
        lbl.frame = CGRectMake(roundf(screenX - 1.0f), roundf(screenY - 0.5f), ceilf(textSize.width + 3.0f), ceilf(textSize.height + 1.0f));
        lbl.hidden = NO;
    }

    // Hide any unused pooled labels
    for (size_t i = cmds.size(); i < self.labelPool.count; ++i) {
        if (!self.labelPool[i].hidden) {
            self.labelPool[i].hidden = YES;
        }
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
            RepogonLog(@"RepogonOverlayView initialized and attached with GPU CALayer acceleration.");
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

    auto applyBlock = ^{
        if (!g_overlayView) {
            RepogonOverlayInit();
        }
        if (g_overlayView) {
            [g_overlayView updateCommands:cmds];
        }
    };

    if ([NSThread isMainThread]) {
        applyBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), applyBlock);
    }
}
