#import "RepogonLogger.h"

#import <os/log.h>
#include <mutex>
#include <cstdio>

static std::mutex g_logMutex;
static NSString *g_logFilePath = nil;
static FILE *g_logFile = NULL;

static void RepogonLogInitLocked(void) {
    if (!g_logFilePath) {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docDir = paths.firstObject;
        if (docDir) {
            g_logFilePath = [docDir stringByAppendingPathComponent:@"repogon_log.txt"];
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:g_logFilePath error:nil];
            unsigned long long size = attrs ? [attrs fileSize] : 0;
            const char *mode = (size > 200 * 1024) ? "w" : "a";
            g_logFile = fopen([g_logFilePath UTF8String], mode);
            if (g_logFile) {
                NSDateFormatter *df = [[NSDateFormatter alloc] init];
                df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
                NSString *dateStr = [df stringFromDate:[NSDate date]];
                fprintf(g_logFile, "\n=== Isaac REPENTOGON iOS Started: %s (mode: %s) ===\n", [dateStr UTF8String], mode);
                fflush(g_logFile);
            }
        }
    }
}

void RepogonLogInit(void) {
    std::lock_guard<std::mutex> lock(g_logMutex);
    RepogonLogInitLocked();
}

NSString *RepogonGetLogFilePath(void) {
    return g_logFilePath;
}

void RepogonLogRaw(const char *message) {
    if (!message) return;
    std::lock_guard<std::mutex> lock(g_logMutex);
    RepogonLogInitLocked();
    NSLog(@"[REPENTOGON] %s", message);
    if (g_logFile) {
        fprintf(g_logFile, "%s\n", message);
        fflush(g_logFile);
    }
}

void RepogonLog(NSString *format, ...) {
    if (!format) return;
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    RepogonLogRaw([msg UTF8String]);
}
