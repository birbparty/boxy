## Atlas texture management compile gate — Milestone 3.
##
## Exercises createAtlasTexture / uploadTile / deleteTexture on the
## Citro3dBackend.  No render output.  Exit via HOME button.
##
## Build:  scripts/build_3ds.sh examples/atlas_compile_3ds.nim atlas_compile_3ds
## Run:    load build/atlas_compile_3ds.3dsx in Azahar (or skip run; compile is the gate)

when not defined(ds3):
  {.error: "atlas_compile_3ds.nim must be compiled with --define:ds3 (use build_3ds.sh)".}

import pixie
import boxy/backends/citro3d_backend
import boxy/bindings/libctru_gfx
import boxy/bindings/citro3d

gfxInitDefault()

let ok = c3dInit(C3D_DEFAULT_CMDBUF_SIZE)
if not ok:
  gfxExit()
  quit(1)

let b = newCitro3dBackend()

# createAtlasTexture: 512×512 VRAM atlas
let atlas = b.createAtlasTexture(512)
doAssert atlas.isAllocated, "createAtlasTexture returned unallocated handle"
doAssert atlas.width == 512 and atlas.height == 512

# uploadTile: 1×1 red pixel at atlas origin
var img = newImage(1, 1)
img.fill(rgba(255, 0, 0, 255))
b.uploadTile(atlas, 0, 0, img, 0)

# deleteTexture: release VRAM and linear mirror
b.deleteTexture(atlas)

# destroy: exercises the backend teardown path in a partially-freed state
# (atlas slot already freed above) to verify idempotency. Device-pending.
b.destroy()

c3dFini()
gfxExit()
