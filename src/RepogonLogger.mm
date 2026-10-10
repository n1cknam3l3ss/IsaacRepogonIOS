#import "RepogonLogger.h"

#import <os/log.h>
#include <mutex>
#include <fstream>

static std::mutex g_logMutex;
static NSString *g_logFilePath = nil;
static std::ofstream g_logFile;

void RepogonLogInit(void) {
    std::lock_guard<std::mutex> lock(g_logMutex);
    if (!g_logFilePath) {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docDir = paths.firstObject;
        if (docDir) {
            g_logFilePath = [docDir stringByAppendingPathComponent:@"repogon_log.txt"];
            g_logFile.open([g_logFilePath UTF8String], std::ios::out | std::ios::app);
            if (g_logFile.is_open()) {
                g_logFile << "\n=== Isaac REPENTOGON iOS Started: "
                          << [[NSDate date] description].UTF8String << " ===\n" << std::flush;
            }
        }
    }
}

NSString *RepogonGetLogFilePath(void) {
    return g_logFilePath;
}

void RepogonLogRaw(const char *message) {
    if (!message) return;
    std::lock_guard<std::mutex> lock(g_logMutex);
    NSLog(@"[REPENTOGON] %s", message);
    if (g_logFile.is_open()) {
        g_logFile << message << "\n" << std::flush;
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
