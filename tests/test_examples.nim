import std/[os, osproc, strutils]

const ignore = [
  # Needs extra dependencies to be installed (windowing libs not in CI).
  "basic_glfw.nim",
  "basic_sdl2.nim",
  "basic_glut.nim",
]

# Scan for files, excluding ds3-only targets (require devkitARM cross-compilation;
# use scripts/build_3ds.sh) and windowing-lib-dependent examples above.
var files: seq[string]
for file in walkDir("examples"):
  if file.kind == pcFile and
    file.path.endsWith(".nim") and
    not file.path.extractFilename.endsWith("_3ds.nim") and
    file.path.extractFilename notin ignore:
      files.add(file.path)

# Compile all
for f in files:
  let cmd = "nim c -d:release --hints:off " & f
  echo "> ", cmd
  if execCmd(cmd) != 0:
    quit("Example did not compile successfully")

# Run all if not in GitHub Actions.
let isGithubActions = getEnv("GITHUB_ACTIONS") == "true"
if not isGithubActions:
  for f in files:
    let cmd = f.changeFileExt("")
    echo "> ", cmd
    if execCmd(cmd) != 0:
      quit("Example did not finish successfully")
