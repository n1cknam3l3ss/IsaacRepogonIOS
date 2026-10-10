#pragma once

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct lua_State lua_State;

bool RepogonLuaInit(void);
void RepogonLuaShutdown(void);
lua_State *RepogonLuaGetState(void);

bool RepogonLuaRunFile(const char *filePath);
bool RepogonLuaRunString(const char *script);

void RepogonLuaDispatchUpdate(void);
void RepogonLuaDispatchRender(void);
void RepogonLuaDispatchNewRoom(void);
void RepogonLuaDispatchNewLevel(void);
void RepogonLuaDispatchGameStarted(bool isContinued);
void RepogonLuaDispatchGameExit(bool shouldSave);

#ifdef __cplusplus
}
#endif
