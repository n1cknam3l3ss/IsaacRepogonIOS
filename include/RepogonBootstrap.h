#pragma once

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

void RepogonStart(void);
void RepogonTick(void);
bool RepogonIsInRun(void);
bool RepogonIsPaused(void);

#ifdef __cplusplus
}
#endif
