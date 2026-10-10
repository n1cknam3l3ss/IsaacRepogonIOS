#pragma once

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

void RepogonModManagerInit(void);
void RepogonModManagerScanAndLoadMods(void);
NSString *RepogonGetModsDirectory(void);

#ifdef __cplusplus
}
#endif
