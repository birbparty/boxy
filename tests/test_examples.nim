import std/[os, osproc, strutils]

const ignore = [
  # Needs extra dependencies to be installed (windowing libs not in CI).
  "basic_glfw.nim",
  "basic_sdl2.nim",
  "basic_glut.nim",
]

# Scan for files, excluding ds3-only targets (require devkitARM cross-compilation;
# use scripts/build_3ds.sh), vita-only targets (require -d:vita + VitaSDK; use
# scripts/build_vita.sh — some are {.error.}-guarded without -d:vita), and
# windowing-lib-dependent examples above.
var files: seq[string]
for file in walkDir("examples"):
  let name = file.path.extractFilename
  if file.kind == pcFile and
    file.path.endsWith(".nim") and
    not name.endsWith("_3ds.nim") and
    not name.endsWith("_vita.nim") and
    not name.startsWith("vita_") and
    name notin ignore:
      files.add(file.path)

# Compile all
for f in files:
  let cmd = "nim c -d:release --hints:off " & f
  echo "> ", cmd
  if execCmd(cmd) != 0:
    quit("Example did not compile successfully")

# Run all if not in GitHub Actions.
# Gate scope: compile + liveness (exit-code-0) only. Windowed examples open
# a window and exit; headless GL examples may still exit 0 even if shaders
# fail to compile and nothing renders. Visual correctness is not verified here.
let isGithubActions = getEnv("GITHUB_ACTIONS") == "true"
if not isGithubActions:
  for f in files:
    let cmd = f.changeFileExt("")
    echo "> ", cmd
    if execCmd(cmd) != 0:
      quit("Example did not finish successfully")
