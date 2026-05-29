## Minimal 3DS toolchain gate — Milestone 1.
##
## Calls gfxInitDefault, runs one aptMainLoop frame, calls gfxExit.
## No boxy, no pixie — just libctru C FFI.
##
## Build:   scripts/build_3ds.sh examples/blank_3ds.nim blank_3ds
## Run:     load build/blank_3ds.3dsx in Azahar emulator

when not defined(ds3):
  {.error: "blank_3ds.nim must be compiled with --define:ds3 (use build_3ds.sh)".}

{.passC: "-I/opt/devkitpro/libctru/include".}

proc gfxInitDefault() {.importc, header: "<3ds/gfx.h>".}
proc gfxExit()        {.importc, header: "<3ds/gfx.h>".}
proc aptMainLoop(): bool {.importc, header: "<3ds/services/apt.h>".}

gfxInitDefault()
while aptMainLoop():
  discard  # black screen — exit via HOME button
gfxExit()
