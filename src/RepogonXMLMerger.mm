#import "RepogonXMLMerger.h"
#import "RepogonLogger.h"

#import <mach-o/dyld.h>
#include <unordered_map>
#include <string>
#include <vector>
#include <mutex>

static std::unordered_map<std::string, std::string> g_mergedPaths;
static std::unordered_map<std::string, int> g_playerTypeMap;
static std::unordered_map<std::string, int> g_entityVariantMap;
static std::unordered_map<std::string, int> g_entityTypeMap;
static std::unordered_map<std::string, int> g_soundMap;
static std::unordered_map<std::string, int> g_musicMap;
static std::mutex g_xmlMutex;

static std::string ToLower(const char *s) {
    if (!s) return "";
    std::string res;
    while (*s) {
        res.push_back(tolower(static_cast<unsigned char>(*s)));
        s++;
    }
    return res;
}

static void InitVanillaMaps(void) {
    if (!g_playerTypeMap.empty()) return;

    // Seed vanilla player types (0-40 in Repentance)
    g_playerTypeMap["isaac"] = 0;
    g_playerTypeMap["magdalene"] = 1;
    g_playerTypeMap["maggy"] = 1;
    g_playerTypeMap["cain"] = 2;
    g_playerTypeMap["judas"] = 3;
    g_playerTypeMap["bluebaby"] = 4;
    g_playerTypeMap["???"] = 4;
    g_playerTypeMap["eve"] = 5;
    g_playerTypeMap["samson"] = 6;
    g_playerTypeMap["azazel"] = 7;
    g_playerTypeMap["lazarus"] = 8;
    g_playerTypeMap["eden"] = 9;
    g_playerTypeMap["the lost"] = 10;
    g_playerTypeMap["lost"] = 10;
    g_playerTypeMap["lazarus2"] = 11;
    g_playerTypeMap["blackjudas"] = 12;
    g_playerTypeMap["lilith"] = 13;
    g_playerTypeMap["keeper"] = 14;
    g_playerTypeMap["apollyon"] = 15;
    g_playerTypeMap["the forgotten"] = 16;
    g_playerTypeMap["forgotten"] = 16;
    g_playerTypeMap["the soul"] = 17;
    g_playerTypeMap["bethany"] = 18;
    g_playerTypeMap["jacob"] = 19;
    g_playerTypeMap["esau"] = 20;
    // Tainted characters: 21 - 40
    g_playerTypeMap["tainted isaac"] = 21;
    g_playerTypeMap["tainted magdalene"] = 22;
    g_playerTypeMap["tainted cain"] = 23;
    g_playerTypeMap["tainted judas"] = 24;
    g_playerTypeMap["tainted bluebaby"] = 25;
    g_playerTypeMap["tainted ???"] = 25;
    g_playerTypeMap["tainted eve"] = 26;
    g_playerTypeMap["tainted samson"] = 27;
    g_playerTypeMap["tainted azazel"] = 28;
    g_playerTypeMap["tainted lazarus"] = 29;
    g_playerTypeMap["tainted eden"] = 30;
    g_playerTypeMap["tainted lost"] = 31;
    g_playerTypeMap["tainted lilith"] = 32;
    g_playerTypeMap["tainted keeper"] = 33;
    g_playerTypeMap["tainted apollyon"] = 34;
    g_playerTypeMap["tainted forgotten"] = 35;
    g_playerTypeMap["tainted bethany"] = 36;
    g_playerTypeMap["tainted jacob"] = 37;
    g_playerTypeMap["tainted lazarus dead"] = 38;
    g_playerTypeMap["tainted jacob esau"] = 39;
    g_playerTypeMap["tainted soul"] = 40;
}

static NSString *GetIsaacAppBundleDirectory(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; ++i) {
        const char *name = _dyld_get_image_name(i);
        if (name && (strstr(name, "The Binding of Isaac") != nullptr || strstr(name, "com.Nicalis.Isaac") != nullptr)) {
            NSString *imgPath = [NSString stringWithUTF8String:name];
            return [imgPath stringByDeletingLastPathComponent];
        }
    }
    return [NSBundle mainBundle].bundlePath;
}

static NSString *FindBaseXML(NSString *fileName) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *searchRoots = [NSMutableArray array];

    NSString *isaacDir = GetIsaacAppBundleDirectory();
    if (isaacDir) [searchRoots addObject:isaacDir];

    NSString *bundleDir = [NSBundle mainBundle].bundlePath;
    if (bundleDir && ![searchRoots containsObject:bundleDir]) {
        [searchRoots addObject:bundleDir];
    }

    // Also check LiveContainer's Applications directory
    NSArray *docPaths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (docPaths.firstObject) {
        NSString *appsDir = [docPaths.firstObject stringByAppendingPathComponent:@"Applications"];
        NSArray *apps = [fm contentsOfDirectoryAtPath:appsDir error:nil];
        for (NSString *app in apps) {
            if ([app containsString:@"Isaac"]) {
                NSString *fullAppPath = [appsDir stringByAppendingPathComponent:app];
                if (![searchRoots containsObject:fullAppPath]) {
                    [searchRoots addObject:fullAppPath];
                }
            }
        }
    }

    NSArray *relPaths = @[
        [NSString stringWithFormat:@"repentance-resources/data/%@", fileName],
        [NSString stringWithFormat:@"repentance-resources/content/%@", fileName],
        [NSString stringWithFormat:@"repentance-resources/%@", fileName],
        [NSString stringWithFormat:@"afterbirthplus-resources/data/%@", fileName],
        [NSString stringWithFormat:@"afterbirthplus-resources/%@", fileName],
        [NSString stringWithFormat:@"afterbirth-resources/data/%@", fileName],
        [NSString stringWithFormat:@"rebirth-resources/data/%@", fileName],
        [NSString stringWithFormat:@"resources/data/%@", fileName],
        [NSString stringWithFormat:@"resources/content/%@", fileName],
        [NSString stringWithFormat:@"resources/%@", fileName],
        [NSString stringWithFormat:@"data/%@", fileName]
    ];

    for (NSString *root in searchRoots) {
        for (NSString *rel in relPaths) {
            NSString *cand = [root stringByAppendingPathComponent:rel];
            if ([fm fileExistsAtPath:cand]) {
                RepogonLog(@"[XMLMerger] Found base XML for %@ at: %@", fileName, cand);
                return cand;
            }
        }
    }

    RepogonLog(@"[XMLMerger] Warning: Base XML not found for %@ across %lu search roots", fileName, (unsigned long)searchRoots.count);
    return nil;
}

static NSString *ExtractRootContent(NSString *xmlContent, NSString *rootTag) {
    if (!xmlContent || !rootTag) return @"";

    NSString *openTagPattern = [NSString stringWithFormat:@"<%@[^>]*>", rootTag];
    NSString *closeTagPattern = [NSString stringWithFormat:@"</%@>", rootTag];

    NSRegularExpression *openRegex = [NSRegularExpression regularExpressionWithPattern:openTagPattern options:NSRegularExpressionCaseInsensitive error:nil];
    NSRegularExpression *closeRegex = [NSRegularExpression regularExpressionWithPattern:closeTagPattern options:NSRegularExpressionCaseInsensitive error:nil];

    NSTextCheckingResult *openMatch = [openRegex firstMatchInString:xmlContent options:0 range:NSMakeRange(0, xmlContent.length)];
    NSTextCheckingResult *closeMatch = [closeRegex firstMatchInString:xmlContent options:0 range:NSMakeRange(0, xmlContent.length)];

    if (openMatch && closeMatch && closeMatch.range.location > NSMaxRange(openMatch.range)) {
        NSUInteger start = NSMaxRange(openMatch.range);
        NSUInteger len = closeMatch.range.location - start;
        return [xmlContent substringWithRange:NSMakeRange(start, len)];
    }
    return @"";
}

void RepogonXMLMergerProcessMods(const std::vector<std::string> &modDirs) {
    std::lock_guard<std::mutex> lock(g_xmlMutex);
    g_mergedPaths.clear();
    InitVanillaMaps();

    if (modDirs.empty()) return;

    NSArray *docPaths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *cacheDir = [docPaths.firstObject stringByAppendingPathComponent:@"cache/xml"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:cacheDir withIntermediateDirectories:YES attributes:nil error:nil];

    struct XMLTarget {
        const char *fileName;
        const char *rootTag;
    };

    XMLTarget targets[] = {
        {"players.xml", "players"},
        {"items.xml", "items"},
        {"entities2.xml", "entities"},
        {"costumes2.xml", "costumes"},
        {"music.xml", "music"},
        {"sounds.xml", "sounds"}
    };

    int customPlayerId = 41;
    int customSoundId = 1001;
    int customMusicId = 101;

    for (const auto &target : targets) {
        NSString *targetFile = [NSString stringWithUTF8String:target.fileName];
        NSString *rootTag = [NSString stringWithUTF8String:target.rootTag];

        std::vector<std::string> contributingMods;
        NSMutableString *injectedXml = [NSMutableString string];

        for (const auto &mDir : modDirs) {
            NSString *modPath = [NSString stringWithUTF8String:mDir.c_str()];
            NSArray *modCandidates = @[
                [modPath stringByAppendingPathComponent:[NSString stringWithFormat:@"content/%@", targetFile]],
                [modPath stringByAppendingPathComponent:[NSString stringWithFormat:@"resources/%@", targetFile]],
                [modPath stringByAppendingPathComponent:targetFile]
            ];

            for (NSString *candidate in modCandidates) {
                if ([fm fileExistsAtPath:candidate]) {
                    NSString *content = [NSString stringWithContentsOfFile:candidate encoding:NSUTF8StringEncoding error:nil];
                    if (content) {
                        NSString *inner = ExtractRootContent(content, rootTag);
                        if (inner.length > 0) {
                            [injectedXml appendFormat:@"\n<!-- Injected from Mod: %@ -->\n%@\n", modPath.lastPathComponent, inner];
                            contributingMods.push_back(mDir);
                            break;
                        }
                    }
                }
            }
        }

        if (contributingMods.empty()) {
            continue; // No mods modified this XML
        }

        // Parse custom IDs and types from injected XML
        if ([targetFile isEqualToString:@"players.xml"]) {
            NSRegularExpression *playerRegex = [NSRegularExpression regularExpressionWithPattern:@"<player\\b[^>]*\\bname=\"([^\"]+)\"" options:NSRegularExpressionCaseInsensitive error:nil];
            NSArray *matches = [playerRegex matchesInString:injectedXml options:0 range:NSMakeRange(0, injectedXml.length)];
            for (NSTextCheckingResult *match in matches) {
                if (match.numberOfRanges > 1) {
                    NSString *pName = [injectedXml substringWithRange:[match rangeAtIndex:1]];
                    std::string lowerName = [pName.lowercaseString UTF8String];
                    if (g_playerTypeMap.find(lowerName) == g_playerTypeMap.end()) {
                        g_playerTypeMap[lowerName] = customPlayerId++;
                        RepogonLog(@"[XMLMerger] Registered Custom PlayerType: %@ -> %d", pName, g_playerTypeMap[lowerName]);
                    }
                }
            }
        } else if ([targetFile isEqualToString:@"entities2.xml"]) {
            NSRegularExpression *entRegex = [NSRegularExpression regularExpressionWithPattern:@"<entity\\b([^>]+)>" options:NSRegularExpressionCaseInsensitive error:nil];
            NSArray *entMatches = [entRegex matchesInString:injectedXml options:0 range:NSMakeRange(0, injectedXml.length)];
            for (NSTextCheckingResult *m in entMatches) {
                if (m.numberOfRanges > 1) {
                    NSString *attrs = [injectedXml substringWithRange:[m rangeAtIndex:1]];
                    NSRegularExpression *nameRe = [NSRegularExpression regularExpressionWithPattern:@"\\bname=\"([^\"]+)\"" options:0 error:nil];
                    NSTextCheckingResult *nameM = [nameRe firstMatchInString:attrs options:0 range:NSMakeRange(0, attrs.length)];
                    NSRegularExpression *varRe = [NSRegularExpression regularExpressionWithPattern:@"\\bvariant=\"([0-9]+)\"" options:0 error:nil];
                    NSTextCheckingResult *varM = [varRe firstMatchInString:attrs options:0 range:NSMakeRange(0, attrs.length)];
                    NSRegularExpression *idRe = [NSRegularExpression regularExpressionWithPattern:@"\\bid=\"([0-9]+)\"" options:0 error:nil];
                    NSTextCheckingResult *idM = [idRe firstMatchInString:attrs options:0 range:NSMakeRange(0, attrs.length)];

                    if (nameM && varM) {
                        NSString *eName = [attrs substringWithRange:[nameM rangeAtIndex:1]];
                        int varVal = [[attrs substringWithRange:[varM rangeAtIndex:1]] intValue];
                        std::string lowerEName = [eName.lowercaseString UTF8String];
                        g_entityVariantMap[lowerEName] = varVal;
                        if (idM) {
                            int idVal = [[attrs substringWithRange:[idM rangeAtIndex:1]] intValue];
                            g_entityTypeMap[lowerEName] = idVal;
                        }
                        RepogonLog(@"[XMLMerger] Registered Custom Entity: %@ -> variant %d", eName, varVal);
                    }
                }
            }
        } else if ([targetFile isEqualToString:@"sounds.xml"]) {
            NSRegularExpression *sndRegex = [NSRegularExpression regularExpressionWithPattern:@"<sound\\b[^>]*\\bname=\"([^\"]+)\"" options:NSRegularExpressionCaseInsensitive error:nil];
            NSArray *sndMatches = [sndRegex matchesInString:injectedXml options:0 range:NSMakeRange(0, injectedXml.length)];
            for (NSTextCheckingResult *m in sndMatches) {
                if (m.numberOfRanges > 1) {
                    NSString *sName = [injectedXml substringWithRange:[m rangeAtIndex:1]];
                    std::string lowerSName = [sName.lowercaseString UTF8String];
                    if (g_soundMap.find(lowerSName) == g_soundMap.end()) {
                        g_soundMap[lowerSName] = customSoundId++;
                        RepogonLog(@"[XMLMerger] Registered Custom Sound: %@ -> %d", sName, g_soundMap[lowerSName]);
                    }
                }
            }
        } else if ([targetFile isEqualToString:@"music.xml"]) {
            NSRegularExpression *musRegex = [NSRegularExpression regularExpressionWithPattern:@"<track\\b[^>]*\\bname=\"([^\"]+)\"" options:NSRegularExpressionCaseInsensitive error:nil];
            NSArray *musMatches = [musRegex matchesInString:injectedXml options:0 range:NSMakeRange(0, injectedXml.length)];
            for (NSTextCheckingResult *m in musMatches) {
                if (m.numberOfRanges > 1) {
                    NSString *mName = [injectedXml substringWithRange:[m rangeAtIndex:1]];
                    std::string lowerMName = [mName.lowercaseString UTF8String];
                    if (g_musicMap.find(lowerMName) == g_musicMap.end()) {
                        g_musicMap[lowerMName] = customMusicId++;
                        RepogonLog(@"[XMLMerger] Registered Custom Music: %@ -> %d", mName, g_musicMap[lowerMName]);
                    }
                }
            }
        }

        NSString *baseXmlPath = FindBaseXML(targetFile);
        if (!baseXmlPath) {
            RepogonLog(@"[XMLMerger] Warning: Base XML not found for %@", targetFile);
            continue;
        }

        NSString *baseContent = [NSString stringWithContentsOfFile:baseXmlPath encoding:NSUTF8StringEncoding error:nil];
        if (!baseContent) continue;

        NSString *closeTag = [NSString stringWithFormat:@"</%@>", rootTag];
        NSRange closeRange = [baseContent rangeOfString:closeTag options:NSBackwardsSearch | NSCaseInsensitiveSearch];
        if (closeRange.location == NSNotFound) continue;

        NSMutableString *merged = [baseContent mutableCopy];
        [merged insertString:injectedXml atIndex:closeRange.location];

        NSString *destPath = [cacheDir stringByAppendingPathComponent:targetFile];
        [merged writeToFile:destPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

        g_mergedPaths[target.fileName] = [destPath UTF8String];
        RepogonLog(@"[XMLMerger] Successfully merged %@ with %zu mods -> %@",
                   targetFile, contributingMods.size(), destPath);
    }
}

const char *RepogonGetMergedXMLPath(const char *xmlFileName) {
    if (!xmlFileName) return nullptr;
    std::lock_guard<std::mutex> lock(g_xmlMutex);
    auto it = g_mergedPaths.find(xmlFileName);
    if (it != g_mergedPaths.end()) {
        return it->second.c_str();
    }
    return nullptr;
}

int RepogonGetPlayerTypeByName(const char *name) {
    if (!name || name[0] == '\0') return -1;
    std::lock_guard<std::mutex> lock(g_xmlMutex);
    std::string lower = ToLower(name);
    auto it = g_playerTypeMap.find(lower);
    if (it != g_playerTypeMap.end()) {
        return it->second;
    }
    return -1;
}

int RepogonGetEntityVariantByName(const char *name) {
    if (!name || name[0] == '\0') return -1;
    std::lock_guard<std::mutex> lock(g_xmlMutex);
    std::string lower = ToLower(name);
    auto it = g_entityVariantMap.find(lower);
    if (it != g_entityVariantMap.end()) {
        return it->second;
    }
    return -1;
}

int RepogonGetEntityTypeByName(const char *name) {
    if (!name || name[0] == '\0') return -1;
    std::lock_guard<std::mutex> lock(g_xmlMutex);
    std::string lower = ToLower(name);
    auto it = g_entityTypeMap.find(lower);
    if (it != g_entityTypeMap.end()) {
        return it->second;
    }
    return -1;
}

int RepogonGetSoundIdByName(const char *name) {
    if (!name || name[0] == '\0') return -1;
    std::lock_guard<std::mutex> lock(g_xmlMutex);
    std::string lower = ToLower(name);
    auto it = g_soundMap.find(lower);
    if (it != g_soundMap.end()) {
        return it->second;
    }
    return -1;
}

int RepogonGetMusicIdByName(const char *name) {
    if (!name || name[0] == '\0') return -1;
    std::lock_guard<std::mutex> lock(g_xmlMutex);
    std::string lower = ToLower(name);
    auto it = g_musicMap.find(lower);
    if (it != g_musicMap.end()) {
        return it->second;
    }
    return -1;
}
