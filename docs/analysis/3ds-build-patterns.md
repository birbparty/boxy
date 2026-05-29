# 3DS Build Patterns from raylib-nim-multiplatform

Analysis of `/Users/punk1290/git/raylib-nim-multiplatform/` for reusable patterns in boxy's 3DS port.

## Compiler Configuration (nim_3ds.cfg)

### Toolchain Binary Resolution
Nim resolves cross-compilers via `$cpu.$os.$cc.exe`. For 3DS: `arm.linux.gcc.exe = "arm-none-eabi-gcc"` at `/opt/devkitpro/devkitARM/bin`.

### Architecture Flags (passC)
```
--passC:"-specs=3dsx.specs"
--passC:"-march=armv6k -mtune=mpcore -mfloat-abi=hard -mtp=soft"
--passC:"-I/opt/devkitpro/libctru/include"
```

- `-specs=3dsx.specs`: devkitARM linker spec for 3DS format; defines startup code location
- `-march=armv6k -mtune=mpcore`: ARM11 MPCore (3DS primary CPU)
- `-mfloat-abi=hard`: Hard-float ABI (hardware FPU)
- `-mtp=soft`: Software thread-pointer access (emits `__aeabi_read_tp` call instead of reading the `CP15`/`TPIDRURO` hardware register); the 3DS userland cannot read the hardware TP register on ARMv6k
- `-I/opt/devkitpro/libctru/include`: Standard libctru SDK headers

### Linker Flags (passL)
```
--passL:"-specs=3dsx.specs -march=armv6k -mfloat-abi=hard"
--passL:"-L/path/to/Nintendo-Raylib/src -lraylib"
--passL:"-L/opt/devkitpro/libctru/lib -lctru"
--passL:"-lm"
--passL:"-L."
```

**Critical:** Nim unconditionally adds `-ldl` for Linux targets. 3DS has no libdl. Build creates empty `libdl.a` stub: `arm-none-eabi-ar rcs libdl.a`.

## config.nims ds3 Block
```nim
elif defined(ds3):
  switch("cpu", "arm")
  switch("os", "linux")   # placeholder; 3DS is not Linux
  switch("mm", "arc")     # ARC: no mmap required
  switch("threads", "off")
  switch("define", "useMalloc")
  switch("define", "nimAllocPagesViaMalloc")
  switch("define", "noSignalHandler")
  switch("opt", "size")
```

All three platforms (PSP, 3DS, Vita) share identical memory settings. ARC avoids mmap dependency.

**Important:** The reference build script (`scripts/build_3ds.sh:28`) passes `--opt:none` on the CLI: `nim c -d:ds3 -d:release --opt:none ...`. The CLI flag overrides `opt:size` from config.nims. The reference project builds with **no optimization** — the explicit `--opt:none` strongly implies `-Os` caused a miscompile on this toolchain. Verify whether `-Os` works for boxy before relying on the config value.

## Build Pipeline (scripts/build_3ds.sh)

```bash
# 1. Environment
export DEVKITPRO="${DEVKITPRO:-/opt/devkitpro}"
export DEVKITARM="${DEVKITARM:-$DEVKITPRO/devkitARM}"
export PATH="$DEVKITPRO/tools/bin:$DEVKITARM/bin:$PATH"

# 2. Config & stub
cp nim_3ds.cfg nim.cfg
"$DEVKITARM/bin/arm-none-eabi-ar" rcs libdl.a

# 3. Compile (produces linked ELF; Nim names it after the module, no extension)
#    The reference uses --opt:none to override opt:size (likely a codegen workaround)
nim c -d:ds3 -d:release --opt:none src/idle_clicker.nim  # adapt entrypoint for boxy

# 4. SMDH metadata
#    Icons must exist first — the reference generates them from a sprite sheet:
#    magick assets/sprite.png -crop 128x128+0+0 +repage -resize 48x48 icon48.png
#    magick assets/sprite.png -crop 128x128+0+0 +repage -resize 24x24 icon24.png
smdhtool --create "Title" "Description" "Author" icon48.png out.smdh icon24.png

# 5. RomFS asset packing
mkromfs3ds romfs_dir/ out.romfs

# 6. Package — input is the ELF produced by step 3
3dsxtool src/idle_clicker out.3dsx --smdh=out.smdh --romfs=out.romfs

# Cleanup — the reference uses trap EXIT to remove stray files:
#   trap 'rm -f nim.cfg libdl.a out.romfs out.smdh icon48.png icon24.png' EXIT
# This matters: cp nim_3ds.cfg nim.cfg leaves nim.cfg in the tree and
# would poison subsequent desktop builds if not removed.
```

RomFS assets mounted at `romfs:/` at runtime (devoptab device prefix, e.g. `"romfs:/assets/image.png"`). Not a Unix path — the colon is the devoptab separator.

## FFI Binding Patterns (raylib_console.nim)

```nim
# Types: importc + header + bycopy
type Vector2* {.importc: "Vector2", header: "raylib.h", bycopy.} = object
  x*, y*: float32

# Enums: explicit size matches C int
type GamepadButton* {.size: sizeof(int32).} = enum
  Unknown, LeftFaceUp, ...

# Constants: copy values from C header (macros not importable)
const LightGray* = Color(r: 200, g: 200, b: 200, a: 255)

# Procs: direct C function mapping
proc closeWindow*() {.importc: "CloseWindow", header: "raylib.h".}

# String wrapping: inner cstring proc + public string proc
proc drawTextImpl(text: cstring, ...) {.importc: "DrawText", header: "raylib.h".}
proc drawText*(text: string, ...) = drawTextImpl(text.cstring, ...)
```

Always use explicit `float32`, not `float`, for C ABI correctness.

## devkitARM Path Conventions

| Resource | Path |
|---|---|
| Root | `$DEVKITPRO` (default `/opt/devkitpro`) |
| Compiler | `$DEVKITARM/bin/arm-none-eabi-gcc` |
| SDK headers | `$DEVKITPRO/libctru/include/` |
| SDK libraries | `$DEVKITPRO/libctru/lib/` |
| Build tools | `$DEVKITPRO/tools/bin/` (3dsxtool, smdhtool, mkromfs3ds) |

## Key Insights for Boxy

1. Nim config is minimal — complexity is acquiring the correct raylib port (Nintendo-Raylib) and devkitARM paths
2. Memory settings (ARC + malloc + no-signals) are identical to PSP/Vita
3. Thin `{.importc.}` bindings work without naylib on console targets — the reference gates the import (`when defined(ds3) or psp or vita: import raylib_console`); desktop/emscripten paths still use naylib
4. nim_3ds.cfg hardcodes project-specific paths — boxy should use env vars or documented setup steps
5. `libdl.a` stub trick is the standard workaround for `-ldl` on Linux targets
6. Build pipeline steps are deterministic and scriptable
