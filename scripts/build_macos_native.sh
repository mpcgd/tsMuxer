#!/usr/bin/env bash

set -exo pipefail

# Run from the repository root whatever directory this was invoked from. Without this the
# script only works when the working directory happens to be the root: "mkdir build" lands
# wherever you stood, and the "cmake .." below then points at a directory with no
# CMakeLists.txt in it. Upstream issue 906 is that failure, reported as a wrong cmake call.
cd "$(dirname "$0")/.."

export MACOSX_DEPLOYMENT_TARGET=10.15

# ---------------------------------------------------------------------------
# Download a Homebrew formula's bottle directly from ghcr.io.
#
# Usage: fetch_bottle <formula> <prefix>
#
# This avoids installing Rosetta Homebrew or the Intel Homebrew installer.
# The bottle tarball is authenticated via a ghcr.io Bearer token and extracted
# to <prefix> with --strip-components=2 so that lib/ and include/ land at the
# top level.
#
# The bottle tag for Intel macOS is "sonoma" — Homebrew's naming for x86_64
# macOS (Sequoia and later dropped Intel runners, so sonoma is the latest
# x86_64 tag).
# ---------------------------------------------------------------------------
fetch_bottle() {
  local formula=$1 prefix=$2
  local tag=sonoma   # latest x86_64 macOS bottle tag

  # Step 1: get the blob SHA256 from the formulae API
  # Note: `local var=$(...)` masks failures on macOS bash 3.2, so declare
  # and assign on separate lines to preserve set -e behavior.
  local blob_sha
  blob_sha=$(curl -fsSL "https://formulae.brew.sh/api/formula/${formula}.json" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['bottle']['stable']['files']['${tag}']['url'].rsplit(':',1)[-1])")

  # Step 2: obtain a pull token from ghcr.io
  local token
  token=$(curl -fsSL "https://ghcr.io/token?scope=repository:homebrew/core/${formula}:pull" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])")

  # Step 3: download and extract the bottle into <prefix>
  local url="https://ghcr.io/v2/homebrew/core/${formula}/blobs/sha256:${blob_sha}"
  curl -fsSL -H "Authorization: Bearer ${token}" "$url" \
    | tar -xz -C "${prefix}" --strip-components=2
}

if [ "${CMAKE_OSX_ARCHITECTURES:-}" = "x86_64" ]; then
  # ======================================================================
  # x86_64 (Intel) cross-build
  #
  # We cannot use Rosetta Homebrew (/usr/local/bin/brew) on arm64 machines
  # because the Xcode Command Line Tools lack x86_64 slices — `git`, `xcrun`,
  # and `clang` all fail under Rosetta with "missing compatible architecture".
  #
  # Instead, download prebuilt x86_64 Homebrew bottles directly from ghcr.io.
  # This requires no Homebrew install, no Rosetta, and no CLT x86_64 support.
  # The bottles contain the exact same static libraries (libfreetype.a,
  # libpng.a, libbz2.a) that a Rosetta Homebrew install would produce.
  #
  # Otherwise the build is identical to arm64: the Qt installed by
  # install-qt-action is the universal2 macOS build (one download, both
  # arm64 and x86_64 slices), and -DCMAKE_OSX_ARCHITECTURES=x86_64 makes
  # CMake select the x86_64 slices for both the CLI and the GUI.
  # ======================================================================
  X86_PREFIX=$(mktemp -d)
  cleanup_x86_prefix() { rm -rf "${X86_PREFIX}"; }
  trap cleanup_x86_prefix EXIT

  echo "==> Downloading x86_64 Homebrew bottles into ${X86_PREFIX} ..." >&2
  fetch_bottle freetype "${X86_PREFIX}"
  fetch_bottle libpng   "${X86_PREFIX}"
  fetch_bottle bzip2    "${X86_PREFIX}"

  # Quick sanity check: the extracted libraries must be x86_64
  for lib in libfreetype.a libpng.a libbz2.a; do
    if ! lipo -info "${X86_PREFIX}/lib/${lib}" 2>/dev/null | grep -q x86_64; then
      echo "ERROR: ${X86_PREFIX}/lib/${lib} is not x86_64" >&2
      exit 1
    fi
  done

  BREW_PREFIX="${X86_PREFIX}"
else
  # arm64 (or unset) — native Homebrew
  brew install freetype
  BREW_PREFIX=$(brew --prefix)
fi

# GUI + CLI for every architecture (macOS Qt is universal2; CMake selects
# the architecture via CMAKE_OSX_ARCHITECTURES). The root CMakeLists also
# auto-enables the GUI when Qt6 is found on PATH, so fail loudly instead of
# silently shipping a CLI-only zip if Qt is ever missing.
CMAKE_GUI_FLAG="-DTSMUXER_GUI=TRUE"

mkdir -p build

pushd build
CMAKE_ARCH_FLAG=""
if [ -n "${CMAKE_OSX_ARCHITECTURES:-}" ]; then
  CMAKE_ARCH_FLAG="-DCMAKE_OSX_ARCHITECTURES=${CMAKE_OSX_ARCHITECTURES}"
fi

cmake -DCMAKE_BUILD_TYPE=Release -DTSMUXER_STATIC_BUILD=TRUE \
  "-DFREETYPE_LDFLAGS=bz2;${BREW_PREFIX}/lib/libpng.a" ${CMAKE_GUI_FLAG} \
  -DWITHOUT_PKGCONFIG=TRUE ${CMAKE_ARCH_FLAG} \
  -DCMAKE_PREFIX_PATH="${BREW_PREFIX}" \
  -DFREETYPE_LIBRARY="${BREW_PREFIX}/lib/libfreetype.a" \
  -DFREETYPE_INCLUDE_DIR_freetype2="${BREW_PREFIX}/include/freetype2" \
  -DFREETYPE_INCLUDE_DIR_ft2build="${BREW_PREFIX}/include/freetype2" ..

if ! num_cores=$(sysctl -n hw.logicalcpu); then
  num_cores=1
fi

make -j${num_cores}

if [ ! -d tsMuxerGUI/tsMuxerGUI.app ]; then
  echo "ERROR: tsMuxerGUI.app was not built; refusing to publish a CLI-only macOS package" >&2
  exit 1
fi

pushd tsMuxerGUI
pushd tsMuxerGUI.app/Contents
# avoid permission denied errors with Info.plist
chmod 664 "$PWD/Info.plist"
defaults write "$PWD/Info.plist" NSPrincipalClass -string NSApplication
defaults write "$PWD/Info.plist" NSHighResolutionCapable -string True
plutil -convert xml1 Info.plist
popd
macdeployqt tsMuxerGUI.app
popd

mkdir -p bin
pushd bin
mv ../tsMuxer/tsmuxer tsMuxeR
mv ../tsMuxerGUI/tsMuxerGUI.app .
cp tsMuxeR tsMuxerGUI.app/Contents/MacOS/

# Sign HERE, not right after macdeployqt. The copy above adds a file to the bundle, and adding
# anything to a signed bundle invalidates the signature, so signing earlier would be undone.
#
# An ad-hoc signature, which is what "-" means, is not a Developer ID and does not remove the
# unidentified developer prompt. What it does remove is "the application is damaged and cannot be
# opened", which is what an unsigned bundle produces on Apple Silicon. On arm64 every Mach-O must
# carry a signature, so the linker gives each binary an ad-hoc one, but the BUNDLE has none and
# that is what macOS objects to.
codesign --force --deep --sign - tsMuxerGUI.app
codesign --verify --deep --strict tsMuxerGUI.app

# -y stores symlinks as symlinks. Without it zip follows them and writes copies, which breaks a
# framework: Versions/Current has to be a link to Versions/A, and QtCore has to be a link to
# Versions/Current/QtCore. Written as real files the bundle is structurally invalid, which is a
# second route to "damaged", and it also stored every Qt library three times. Measured on the
# 2.18.9 arm64 package: 127 entries, zero symlinks, and 98 MB of duplication.
zip -9 -r -y mac.zip tsMuxeR tsMuxerGUI.app

# Check the package rather than trusting the flags, because both faults this replaces were
# silent: the build succeeded, the zip uploaded, and the app would not open. zipinfo marks a
# symlink with l in the first column.
links=$(zipinfo mac.zip | grep -c '^l' || true)
echo "symlinks stored in package: ${links}"
if [ "${links}" -eq 0 ]; then
  echo "ERROR: no symlinks in the package, so the .app frameworks are invalid" >&2
  exit 1
fi
if ! unzip -l mac.zip | grep -q '_CodeSignature/CodeResources'; then
  echo "ERROR: the .app is not signed, which reads as damaged on Apple Silicon" >&2
  exit 1
fi
popd
