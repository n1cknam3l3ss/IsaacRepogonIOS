#pragma once

#import <Foundation/Foundation.h>
#include <string>
#include <vector>

#ifdef __cplusplus
extern "C" {
#endif

void RepogonVFSInit(void);
void RepogonVFSAddModDirectory(const char *modDir);
void RepogonVFSClearModDirectories(void);
const char *RepogonVFSRedirectPath(const char *originalPath);

#ifdef __cplusplus
}
#endif
