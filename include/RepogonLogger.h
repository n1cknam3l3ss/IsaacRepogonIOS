#pragma once

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

void RepogonLogInit(void);
void RepogonLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
void RepogonLogRaw(const char *message);
NSString *RepogonGetLogFilePath(void);

#ifdef __cplusplus
}
#endif
