SHELL := /bin/zsh

PROJECT_ROOT := $(CURDIR)
SDK := $(shell xcrun --sdk iphoneos --show-sdk-path)
CLANG := $(shell xcrun --sdk iphoneos --find clang)
CLANGXX := $(shell xcrun --sdk iphoneos --find clang++)
MIN_IOS ?= 15.0
EXTRA_CFLAGS ?=

DYLIB := $(PROJECT_ROOT)/build/IsaacRepogonIOS.dylib
DEB_STAGE := $(PROJECT_ROOT)/package/stage
DEB := $(PROJECT_ROOT)/packages/IsaacRepogonIOS-rootless.deb
LIVECONTAINER_FRAMEWORK := $(PROJECT_ROOT)/build/IsaacRepogonIOS.framework
LIVECONTAINER_ZIP := $(PROJECT_ROOT)/packages/IsaacRepogonIOS-LiveContainer.framework.zip
DIST := $(PROJECT_ROOT)/dist
RELEASE_ZIP := $(DIST)/IsaacRepogonIOS.zip

LUA_DIR := $(PROJECT_ROOT)/src/lua
LUA_SRCS := $(wildcard $(LUA_DIR)/*.c)
LUA_OBJS := $(patsubst $(LUA_DIR)/%.c, $(PROJECT_ROOT)/build/lua/%.o, $(LUA_SRCS))

OBJCXX_DIR := $(PROJECT_ROOT)/src
OBJCXX_SRCS := $(wildcard $(OBJCXX_DIR)/*.mm)
OBJCXX_OBJS := $(patsubst $(OBJCXX_DIR)/%.mm, $(PROJECT_ROOT)/build/src/%.o, $(OBJCXX_SRCS))

C_SRCS := $(wildcard $(OBJCXX_DIR)/*.c)
C_OBJS := $(patsubst $(OBJCXX_DIR)/%.c, $(PROJECT_ROOT)/build/src/%_c.o, $(C_SRCS))

.PHONY: all dylib package livecontainer dist clean

all: dylib package livecontainer dist

$(PROJECT_ROOT)/build/lua/%.o: $(LUA_DIR)/%.c
	@mkdir -p "$(PROJECT_ROOT)/build/lua"
	"$(CLANG)" -isysroot "$(SDK)" -arch arm64 -miphoneos-version-min="$(MIN_IOS)" \
		-O2 -DLUA_USE_POSIX -I"$(LUA_DIR)" -c $< -o $@

$(PROJECT_ROOT)/build/src/%_c.o: $(OBJCXX_DIR)/%.c
	@mkdir -p "$(PROJECT_ROOT)/build/src"
	"$(CLANG)" -isysroot "$(SDK)" -arch arm64 -miphoneos-version-min="$(MIN_IOS)" \
		-O2 -I"$(PROJECT_ROOT)/include" -c $< -o $@

$(PROJECT_ROOT)/build/src/%.o: $(OBJCXX_DIR)/%.mm
	@mkdir -p "$(PROJECT_ROOT)/build/src"
	"$(CLANGXX)" -isysroot "$(SDK)" -arch arm64 -miphoneos-version-min="$(MIN_IOS)" \
		-std=c++17 -fobjc-arc -fmodules -O2 $(EXTRA_CFLAGS) -I"$(PROJECT_ROOT)/include" -I"$(LUA_DIR)" -c $< -o $@

dylib: $(DYLIB)

$(DYLIB): $(LUA_OBJS) $(OBJCXX_OBJS) $(C_OBJS)
	@mkdir -p "$(PROJECT_ROOT)/build"
	"$(CLANGXX)" -isysroot "$(SDK)" -arch arm64 -miphoneos-version-min="$(MIN_IOS)" \
		-dynamiclib -Wl,-install_name,@rpath/$(notdir $(DYLIB)) -Wl,-dead_strip \
		-Wl,-exported_symbols_list,"$(PROJECT_ROOT)/package/exports.txt" \
		$(LUA_OBJS) $(OBJCXX_OBJS) $(C_OBJS) -framework Foundation -framework UIKit -framework QuartzCore -lc++ -o "$(DYLIB)"
	xcrun strip -x "$(DYLIB)"
	@if command -v codesign >/dev/null 2>&1; then codesign --force --sign - --timestamp=none "$(DYLIB)"; elif command -v ldid >/dev/null 2>&1; then ldid -S "$(DYLIB)"; fi

package: dylib
	rm -rf "$(DEB_STAGE)"
	mkdir -p "$(DEB_STAGE)/DEBIAN" "$(DEB_STAGE)/var/jb/Library/MobileSubstrate/DynamicLibraries"
	cp "$(PROJECT_ROOT)/package/control" "$(DEB_STAGE)/DEBIAN/control"
	cp "$(PROJECT_ROOT)/package/IsaacRepogonIOS.plist" "$(DEB_STAGE)/var/jb/Library/MobileSubstrate/DynamicLibraries/IsaacRepogonIOS.plist"
	cp "$(DYLIB)" "$(DEB_STAGE)/var/jb/Library/MobileSubstrate/DynamicLibraries/IsaacRepogonIOS.dylib"
	mkdir -p "$(PROJECT_ROOT)/packages"
	dpkg-deb --root-owner-group --build "$(DEB_STAGE)" "$(DEB)"

livecontainer: dylib
	rm -rf "$(LIVECONTAINER_FRAMEWORK)"
	mkdir -p "$(LIVECONTAINER_FRAMEWORK)"
	cp "$(DYLIB)" "$(LIVECONTAINER_FRAMEWORK)/IsaacRepogonIOS"
	cp "$(PROJECT_ROOT)/livecontainer/Info.plist" "$(LIVECONTAINER_FRAMEWORK)/Info.plist"
	chmod 755 "$(LIVECONTAINER_FRAMEWORK)/IsaacRepogonIOS"
	mkdir -p "$(PROJECT_ROOT)/packages"
	rm -f "$(LIVECONTAINER_ZIP)"
	/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$(LIVECONTAINER_FRAMEWORK)" "$(LIVECONTAINER_ZIP)"

dist: package livecontainer
	mkdir -p "$(DIST)"
	cp "$(DYLIB)" "$(DIST)/"
	cp "$(DEB)" "$(DIST)/"
	cp "$(LIVECONTAINER_ZIP)" "$(DIST)/"
	cd "$(DIST)" && zip -r "$(RELEASE_ZIP)" IsaacRepogonIOS.dylib "$(notdir $(DEB))" "$(notdir $(LIVECONTAINER_ZIP))"

clean:
	rm -rf "$(PROJECT_ROOT)/build" "$(PROJECT_ROOT)/packages" "$(PROJECT_ROOT)/dist" "$(DEB_STAGE)"
