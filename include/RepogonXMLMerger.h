#pragma once

#import <Foundation/Foundation.h>
#include <string>
#include <vector>

#ifdef __cplusplus
extern "C" {
#endif

void RepogonXMLMergerProcessMods(const std::vector<std::string> &modDirs);
const char *RepogonGetMergedXMLPath(const char *xmlFileName);

int RepogonGetPlayerTypeByName(const char *name);
int RepogonGetEntityVariantByName(const char *name);
int RepogonGetEntityTypeByName(const char *name);
int RepogonGetSoundIdByName(const char *name);
int RepogonGetMusicIdByName(const char *name);

#ifdef __cplusplus
}
#endif

