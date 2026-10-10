#import "RepogonXMLMerger.h"
#import "RepogonLogger.h"

#include <unordered_map>
#include <string>
#include <vector>

static std::unordered_map<std::string, std::string> g_mergedPaths;

static NSString *FindBaseXML(NSString *fileName) {
    NSBundle *bundle = [NSBundle mainBundle];
    NSString *bundlePath = bundle.bundlePath;
    NSFileManager *fm = [NSFileManager defaultManager];

    NSArray *candidates = @[
        [bundlePath stringByAppendingPathComponent:[NSString stringWithFormat:@"repentance-resources/data/%@", fileName]],
        [bundlePath stringByAppendingPathComponent:[NSString stringWithFormat:@"repentance-resources/content/%@", fileName]],
        [bundlePath stringByAppendingPathComponent:[NSString stringWithFormat:@"repentance-resources/%@", fileName]],
        [bundlePath stringByAppendingPathComponent:[NSString stringWithFormat:@"afterbirthplus-resources/data/%@", fileName]],
        [bundlePath stringByAppendingPathComponent:[NSString stringWithFormat:@"afterbirthplus-resources/%@", fileName]],
        [bundlePath stringByAppendingPathComponent:[NSString stringWithFormat:@"afterbirth-resources/data/%@", fileName]],
        [bundlePath stringByAppendingPathComponent:[NSString stringWithFormat:@"rebirth-resources/data/%@", fileName]],
        [bundlePath stringByAppendingPathComponent:[NSString stringWithFormat:@"resources/data/%@", fileName]],
        [bundlePath stringByAppendingPathComponent:[NSString stringWithFormat:@"resources/content/%@", fileName]],
        [bundlePath stringByAppendingPathComponent:[NSString stringWithFormat:@"resources/%@", fileName]],
        [bundlePath stringByAppendingPathComponent:[NSString stringWithFormat:@"data/%@", fileName]]
    ];

    for (NSString *p in candidates) {
        if ([fm fileExistsAtPath:p]) {
            return p;
        }
    }
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
    g_mergedPaths.clear();

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
        {"costumes2.xml", "costumes"}
    };

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
    auto it = g_mergedPaths.find(xmlFileName);
    if (it != g_mergedPaths.end()) {
        return it->second.c_str();
    }
    return nullptr;
}
