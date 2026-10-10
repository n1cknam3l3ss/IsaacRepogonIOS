#import "RepogonVFS.h"
#import "RepogonXMLMerger.h"
#import "RepogonLogger.h"
#import "fishhook.h"

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <cstdarg>
#include <mutex>
#include <unordered_map>
#include <vector>
#include <string>

namespace {

static std::vector<std::string> g_modDirs;
static std::unordered_map<std::string, std::string> g_redirectCache;
static std::recursive_mutex g_vfsMutex;
static thread_local bool t_inVfs = false;

static int (*orig_open)(const char *path, int oflag, ...) = nullptr;
static FILE *(*orig_fopen)(const char *path, const char *mode) = nullptr;
static int (*orig_stat)(const char *path, struct stat *buf) = nullptr;
static int (*orig_stat64)(const char *path, struct stat *buf) = nullptr;
static int (*orig_lstat)(const char *path, struct stat *buf) = nullptr;
static int (*orig_lstat64)(const char *path, struct stat *buf) = nullptr;
static int (*orig_access)(const char *path, int amode) = nullptr;

static const char *kMarkers[] = {
    "repentance-resources/",
    "afterbirthplus-resources/",
    "afterbirth-resources/",
    "rebirth-resources/",
    "resources-dlc3/",
    "resources/",
    "content/",
    "data/"
};

static const char *GetBaseName(const char *path) {
    if (!path) return "";
    const char *lastSlash = strrchr(path, '/');
    return lastSlash ? lastSlash + 1 : path;
}

static bool CheckFileExists(const std::string &path) {
    if (orig_access) return orig_access(path.c_str(), F_OK) == 0;
    struct stat st;
    if (orig_stat) return orig_stat(path.c_str(), &st) == 0;
    return access(path.c_str(), F_OK) == 0;
}

} // namespace

void RepogonVFSAddModDirectory(const char *modDir) {
    if (!modDir) return;
    std::lock_guard<std::recursive_mutex> lock(g_vfsMutex);
    g_modDirs.push_back(modDir);
    g_redirectCache.clear();
    RepogonLog(@"[VFS] Registered active mod directory: %s", modDir);
}

void RepogonVFSClearModDirectories(void) {
    std::lock_guard<std::recursive_mutex> lock(g_vfsMutex);
    g_modDirs.clear();
    g_redirectCache.clear();
}

const char *RepogonVFSRedirectPath(const char *originalPath) {
    if (!originalPath || originalPath[0] == '\0') return originalPath;
    if (t_inVfs) return originalPath;

    // Fast check: if the path is already inside mods/ or cache/, skip redirection
    if (strstr(originalPath, "/mods/") != nullptr ||
        strstr(originalPath, "/cache/") != nullptr) {
        return originalPath;
    }

    struct VfsGuard {
        VfsGuard() { t_inVfs = true; }
        ~VfsGuard() { t_inVfs = false; }
    } guard;

    std::lock_guard<std::recursive_mutex> lock(g_vfsMutex);

    auto it = g_redirectCache.find(originalPath);
    if (it != g_redirectCache.end()) {
        return it->second.c_str();
    }

    // 1. Check if this is an XML file that was merged dynamically (e.g. players.xml, entities2.xml)
    const char *baseName = GetBaseName(originalPath);
    if (strstr(baseName, ".xml") != nullptr) {
        const char *mergedXml = RepogonGetMergedXMLPath(baseName);
        if (mergedXml) {
            g_redirectCache[originalPath] = mergedXml;
            RepogonLog(@"[VFS] Redirected XML: %s -> %s", originalPath, mergedXml);
            return g_redirectCache[originalPath].c_str();
        }
    }

    // Look for resource directory marker in path
    const char *rel = nullptr;
    for (const char *marker : kMarkers) {
        const char *pos = strstr(originalPath, marker);
        if (pos) {
            rel = pos + strlen(marker);
            break;
        }
    }

    if (!rel || rel[0] == '\0') {
        g_redirectCache[originalPath] = originalPath;
        return originalPath;
    }

    while (rel[0] == '/') rel++; // Skip leading slash

    // 2. Check active mod directories for the requested asset
    for (const auto &mDir : g_modDirs) {
        std::string cand1 = mDir + "/resources/" + rel;
        if (CheckFileExists(cand1)) {
            g_redirectCache[originalPath] = cand1;
            RepogonLog(@"[VFS] Redirected Asset: %s -> %s", originalPath, cand1.c_str());
            return g_redirectCache[originalPath].c_str();
        }

        std::string cand2 = mDir + "/content/" + rel;
        if (CheckFileExists(cand2)) {
            g_redirectCache[originalPath] = cand2;
            RepogonLog(@"[VFS] Redirected Content: %s -> %s", originalPath, cand2.c_str());
            return g_redirectCache[originalPath].c_str();
        }

        std::string cand3 = mDir + "/" + rel;
        if (CheckFileExists(cand3)) {
            g_redirectCache[originalPath] = cand3;
            RepogonLog(@"[VFS] Redirected Root: %s -> %s", originalPath, cand3.c_str());
            return g_redirectCache[originalPath].c_str();
        }
    }

    // Not found in any mod: cache identity mapping
    g_redirectCache[originalPath] = originalPath;
    return originalPath;
}

static int repogon_open(const char *path, int oflag, ...) {
    if (t_inVfs) {
        if (oflag & O_CREAT) {
            va_list args;
            va_start(args, oflag);
            mode_t mode = static_cast<mode_t>(va_arg(args, int));
            va_end(args);
            return orig_open ? orig_open(path, oflag, mode) : open(path, oflag, mode);
        }
        return orig_open ? orig_open(path, oflag) : open(path, oflag);
    }
    const char *target = RepogonVFSRedirectPath(path);
    if (!target) target = path;

    if (oflag & O_CREAT) {
        va_list args;
        va_start(args, oflag);
        mode_t mode = static_cast<mode_t>(va_arg(args, int));
        va_end(args);
        return orig_open ? orig_open(target, oflag, mode) : open(target, oflag, mode);
    }
    return orig_open ? orig_open(target, oflag) : open(target, oflag);
}

static FILE *repogon_fopen(const char *path, const char *mode) {
    if (t_inVfs) {
        return orig_fopen ? orig_fopen(path, mode) : fopen(path, mode);
    }
    const char *target = RepogonVFSRedirectPath(path);
    if (!target) target = path;
    return orig_fopen ? orig_fopen(target, mode) : fopen(target, mode);
}

static int repogon_stat(const char *path, struct stat *buf) {
    if (t_inVfs) {
        if (orig_stat) return orig_stat(path, buf);
        if (orig_stat64) return orig_stat64(path, buf);
        return stat(path, buf);
    }
    const char *target = RepogonVFSRedirectPath(path);
    if (!target) target = path;
    if (orig_stat) return orig_stat(target, buf);
    if (orig_stat64) return orig_stat64(target, buf);
    return stat(target, buf);
}

static int repogon_lstat(const char *path, struct stat *buf) {
    if (t_inVfs) {
        if (orig_lstat) return orig_lstat(path, buf);
        if (orig_lstat64) return orig_lstat64(path, buf);
        return lstat(path, buf);
    }
    const char *target = RepogonVFSRedirectPath(path);
    if (!target) target = path;
    if (orig_lstat) return orig_lstat(target, buf);
    if (orig_lstat64) return orig_lstat64(target, buf);
    return lstat(target, buf);
}

static int repogon_access(const char *path, int amode) {
    if (t_inVfs) {
        return orig_access ? orig_access(path, amode) : access(path, amode);
    }
    const char *target = RepogonVFSRedirectPath(path);
    if (!target) target = path;
    return orig_access ? orig_access(target, amode) : access(target, amode);
}

void RepogonVFSInit(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        struct rebinding rebs[] = {
            {"fopen", reinterpret_cast<void *>(repogon_fopen), reinterpret_cast<void **>(&orig_fopen)},
            {"open", reinterpret_cast<void *>(repogon_open), reinterpret_cast<void **>(&orig_open)},
            {"access", reinterpret_cast<void *>(repogon_access), reinterpret_cast<void **>(&orig_access)},
            {"stat", reinterpret_cast<void *>(repogon_stat), reinterpret_cast<void **>(&orig_stat)},
            {"lstat", reinterpret_cast<void *>(repogon_lstat), reinterpret_cast<void **>(&orig_lstat)},
            {"stat$INODE64", reinterpret_cast<void *>(repogon_stat), reinterpret_cast<void **>(&orig_stat64)},
            {"lstat$INODE64", reinterpret_cast<void *>(repogon_lstat), reinterpret_cast<void **>(&orig_lstat64)}
        };

        int rc = rebind_symbols(rebs, sizeof(rebs) / sizeof(rebs[0]));
        RepogonLog(@"[VFS] Virtual File System & Asset Redirection initialized (rebind status: %d).", rc);
    });
}
