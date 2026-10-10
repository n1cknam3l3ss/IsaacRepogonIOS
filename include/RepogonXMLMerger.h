#pragma once

#import <Foundation/Foundation.h>
#include <string>
#include <vector>

#ifdef __cplusplus
extern "C" {
#endif

void RepogonXMLMergerProcessMods(const std::vector<std::string> &modDirs);
const char *RepogonGetMergedXMLPath(const char *xmlFileName);

#ifdef __cplusplus
}
#endif
