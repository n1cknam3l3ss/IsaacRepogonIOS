#pragma once

#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

void RepogonOverlayInit(void);
void RepogonOverlayAddText(NSString *text, float x, float y, float r, float g, float b, float a);
void RepogonOverlayAddScaledText(NSString *text, float x, float y, float sx, float sy, float r, float g, float b, float a);
void RepogonOverlayClear(void);
void RepogonOverlayFlush(void);

#ifdef __cplusplus
}
#endif
