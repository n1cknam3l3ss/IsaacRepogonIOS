# Isaac REPENTOGON iOS

**REPENTOGON / Lua Modding Runtime & Script Loader for The Binding of Isaac on iOS**

Isaac REPENTOGON iOS embeds a complete **Lua 5.3** virtual machine directly into the iOS build of *The Binding of Isaac: Repentance*, restoring the modding API stripped from the mobile release.

---

## 🌟 Features

- **Embedded Lua 5.3 Runtime**: Standard, high-performance Lua 5.3 environment.
- **Mod Directory (`Documents/mods/`)**: Place mod folders in `Documents/mods/` (accessible via LiveContainer or Files app).
- **Core ModCallbacks**:
  - `MC_POST_UPDATE` (Game loop tick)
  - `MC_POST_RENDER` (Render loop pass)
  - `MC_POST_PEFFECT_UPDATE` (Player per-frame update)
  - `MC_POST_NEW_ROOM`
  - `MC_POST_NEW_LEVEL`
  - `MC_POST_GAME_STARTED`
  - `MC_PRE_GAME_EXIT`
- **Isaac Global API**:
  - `Isaac.DebugString(str)`
  - `Isaac.GetPlayer(index)` (hearts, coins, bombs, keys, damage, speed, active item, etc.)
  - `Isaac.GetRoom()` (room type, center position, grid index, clear state)
  - `Isaac.GetGame()` (seeds, frame count, level, spawn)
  - `Isaac.Spawn(type, variant, subtype, pos, vel, spawner)`
  - `Isaac.FindByType(type, variant, subtype)`
  - `Isaac.RenderText(text, x, y, r, g, b, a)` & `Isaac.RenderScaledText(...)`
- **In-Game Text Overlay**: Transparent, touch-passthrough UIKit overlay that renders custom mod text.
- **Direct Logging**: All `print(...)` and `Isaac.DebugString(...)` outputs are saved to `Documents/repogon_log.txt`.
- **Guaranteed Void Portals**: 100% Void portal spawn logic after Mega Satan, Mother, The Lamb, and ??? included out of the box.

---

## 📂 Installing Mods

1. Open Files app (or LiveContainer documents).
2. Navigate to `Documents/mods/`.
3. Create or drop a mod folder (e.g. `Documents/mods/MyMod/`).
4. Ensure `main.lua` is located inside the mod folder (`Documents/mods/MyMod/main.lua`).
5. Launch the game! Logs will be recorded in `Documents/repogon_log.txt`.

---

## 🛠️ Building

Built automatically on macOS runners via GitHub Actions CI:
```bash
make all
```

Outputs:
- `build/IsaacRepogonIOS.dylib` (Raw dylib for sideloading/injection)
- `packages/IsaacRepogonIOS-LiveContainer.framework.zip` (For LiveContainer)
- `packages/IsaacRepogonIOS-rootless.deb` (For rootless jailbreaks)
