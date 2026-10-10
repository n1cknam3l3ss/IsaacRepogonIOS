#pragma once

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

void RepogonStart(void);
void RepogonTick(void);
bool RepogonIsInRun(void);

#ifdef __cplusplus
}
#endif
