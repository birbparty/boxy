## Nim FFI bindings for libctru HID (Human Interface Device) input.
##
## Binds:
##   HID polling:  hidScanInput, hidKeysDown, hidKeysHeld, hidKeysUp
##   Key constants: KEY_START, KEY_SELECT, KEY_A, KEY_B, KEY_X, KEY_Y,
##                  KEY_L, KEY_R, KEY_ZL, KEY_ZR, KEY_DLEFT, KEY_DRIGHT,
##                  KEY_DUP, KEY_DDOWN
##
## Header: <3ds/services/hid.h> (included transitively by <3ds.h>).
## The -I/opt/devkitpro/libctru/include path is set by nim_3ds.cfg.
##
## Usage: import only when --define:ds3 is active. Call hidScanInput once
## per frame, then test hidKeysDown(0) against key constants.
##
## Typical exit-key pattern:
##   while aptMainLoop():
##     hidScanInput()
##     if (hidKeysDown(0) and KEY_START) != 0:
##       break

when not defined(ds3):
  {.error: "libctru_hid.nim must be compiled with --define:ds3 (use scripts/build_3ds.sh)".}

# ---------------------------------------------------------------------------
# Key bit constants (from <3ds/services/hid.h>)
#
# These map to the HID bitmask returned by hidKeysDown/Held/Up.
# Each constant is a power-of-two bit flag; combine with `and`/`or`.
# ---------------------------------------------------------------------------

const
  KEY_A*      = 0x00000001'u32  ## A button
  KEY_B*      = 0x00000002'u32  ## B button
  KEY_SELECT* = 0x00000004'u32  ## SELECT button
  KEY_START*  = 0x00000008'u32  ## START button
  KEY_DRIGHT* = 0x00000010'u32  ## D-Pad Right
  KEY_DLEFT*  = 0x00000020'u32  ## D-Pad Left
  KEY_DUP*    = 0x00000040'u32  ## D-Pad Up
  KEY_DDOWN*  = 0x00000080'u32  ## D-Pad Down
  KEY_R*      = 0x00000100'u32  ## R shoulder button
  KEY_L*      = 0x00000200'u32  ## L shoulder button
  KEY_X*      = 0x00000400'u32  ## X button
  KEY_Y*      = 0x00000800'u32  ## Y button
  KEY_ZL*     = 0x00002000'u32  ## ZL (New 3DS only)
  KEY_ZR*     = 0x00004000'u32  ## ZR (New 3DS only)

# ---------------------------------------------------------------------------
# HID polling functions (from <3ds/services/hid.h>)
#
# Call hidScanInput() once per frame (before any hidKeysDown/Held/Up query).
# id parameter is the controller id (0 for the 3DS built-in controls).
# ---------------------------------------------------------------------------

proc hidScanInput*()
  {.importc: "hidScanInput", header: "<3ds/services/hid.h>".}
  ## Scan the HID hardware state. Must be called once per frame.

proc hidKeysDown*(id: uint32): uint32
  {.importc: "hidKeysDown", header: "<3ds/services/hid.h>".}
  ## Returns bitmask of keys just pressed this frame (rising edge).

proc hidKeysHeld*(id: uint32): uint32
  {.importc: "hidKeysHeld", header: "<3ds/services/hid.h>".}
  ## Returns bitmask of keys currently held (any duration).

proc hidKeysUp*(id: uint32): uint32
  {.importc: "hidKeysUp", header: "<3ds/services/hid.h>".}
  ## Returns bitmask of keys just released this frame (falling edge).
