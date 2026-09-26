#!/data/data/com.termux/files/usr/bin/bash
# opencode-termux installer
#
# Downloads the latest opencode release (Bun-compiled glibc binary for
# aarch64), builds the seccomp SIGSYS shim, and installs a launcher under
# ~/.opencode/ so opencode runs natively on Termux (Android 10/11).
#
# Usage: ./install.sh
#        curl -fsSL https://raw.githubusercontent.com/HanSoBored/opencode-termux/main/install.sh | bash
# Env:   OPENCODE_REPO=anomalyco/opencode      repo owning the release
#        OPENCODE_VERSION=vX.Y.Z or "latest"   release to fetch (default: latest)
#        OPENCODE_DIR=~/.opencode              install location
#        OPENCODE_FORCE=1                      re-download even if binary exists
#        OPENCODE_RAW_REPO / OPENCODE_REF       where to fetch src/ from when not
#                                               running inside a checkout
set -euo pipefail

OPENCODE_REPO="${OPENCODE_REPO:-anomalyco/opencode}"
OPENCODE_VERSION="${OPENCODE_VERSION:-latest}"
OPENCODE_DIR="${OPENCODE_DIR:-$HOME/.opencode}"
OPENCODE_RAW_REPO="${OPENCODE_RAW_REPO:-HanSoBored/opencode-termux}"
OPENCODE_REF="${OPENCODE_REF:-main}"
ARCH="$(uname -m)"

# When piped to bash there is no script file, so fall back to the CWD and let
# the source fetch below pull src/ straight from GitHub.
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    SRC_DIR="$PWD"
fi

say()  { printf '\033[1;32m[opencode-termux]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[opencode-termux]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[opencode-termux]\033[0m ERROR: %s\n' "$*" >&2; exit 1; }

[ -n "${PREFIX:-}" ] || die "must run inside Termux"
[ "$ARCH" = "aarch64" ] || die "unsupported architecture: $ARCH (aarch64 only)"
[ -x "$PREFIX/glibc/bin/ld.so" ] || die "Termux glibc not found. Install it first:

    pkg install glibc-repo
    pkg install glibc glibc-runner
"
command -v clang >/dev/null || die "clang not found. Install it: pkg install clang"
command -v curl  >/dev/null || die "curl not found. Install it: pkg install curl"

# Not running from a checkout (curl | bash): pull just the two source files we
# need straight off GitHub instead of cloning the whole repo.
SRC_TMP=""
if [ ! -f "$SRC_DIR/src/libseccomp-shim.c" ] || [ ! -f "$SRC_DIR/src/opencode" ]; then
    say "no local checkout — fetching src/ from $OPENCODE_RAW_REPO@$OPENCODE_REF ..."
    SRC_TMP="$(mktemp -d)"
    SRC_DIR="$SRC_TMP"
    mkdir -p "$SRC_DIR/src"
    RAW="https://raw.githubusercontent.com/$OPENCODE_RAW_REPO/$OPENCODE_REF"
    curl -fsSL "$RAW/src/libseccomp-shim.c" -o "$SRC_DIR/src/libseccomp-shim.c" \
        || die "could not fetch src/libseccomp-shim.c from $RAW"
    curl -fsSL "$RAW/src/opencode"          -o "$SRC_DIR/src/opencode" \
        || die "could not fetch src/opencode from $RAW"
fi

mkdir -p "$OPENCODE_DIR/bin" "$OPENCODE_DIR/lib"

# ---------------------------------------------------------------- 1. binary
BIN="$OPENCODE_DIR/bin/opencode-bin"
if [ -x "$BIN" ] && [ "${OPENCODE_FORCE:-0}" != "1" ]; then
    say "opencode binary already present, keeping it (OPENCODE_FORCE=1 to re-download)"
else
    if [ "$OPENCODE_VERSION" = "latest" ]; then
        say "resolving latest release of $OPENCODE_REPO ..."
        API="https://api.github.com/repos/$OPENCODE_REPO/releases/latest"
        ASSET_URL="$(curl -fsSL "$API" \
            | grep -oE '"browser_download_url": *"[^"]*opencode-linux-arm64\.tar\.gz"' \
            | head -1 | sed -E 's/.*"browser_download_url": *"([^"]+)"/\1/')"
        [ -n "$ASSET_URL" ] || die "could not find opencode-linux-arm64.tar.gz in the latest release"
    else
        ASSET_URL="https://github.com/$OPENCODE_REPO/releases/download/$OPENCODE_VERSION/opencode-linux-arm64.tar.gz"
    fi

    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    say "downloading $ASSET_URL ..."
    curl -fL "$ASSET_URL" -o "$TMP/opencode.tar.gz" || die "download failed"
    tar -xzf "$TMP/opencode.tar.gz" -C "$TMP" || die "extract failed"
    [ -f "$TMP/opencode" ] || die "unexpected archive layout (expected a single 'opencode' file)"
    mv "$TMP/opencode" "$BIN"
    rm -rf "$TMP"
    trap - EXIT
    chmod 755 "$BIN"
    say "installed binary: $BIN"
fi

# ---------------------------------------------------------------- 2. shim
say "building seccomp shim ..."
cp "$SRC_DIR/src/libseccomp-shim.c" "$OPENCODE_DIR/lib/libseccomp-shim.c"
clang --target=aarch64-linux-gnu --sysroot="$PREFIX/glibc" \
      -shared -fPIC -O2 -nostdlib \
      -o "$OPENCODE_DIR/lib/libseccomp-shim.so" \
      "$OPENCODE_DIR/lib/libseccomp-shim.c" \
    || die "shim build failed (clang + glibc sysroot required)"
say "built shim: $OPENCODE_DIR/lib/libseccomp-shim.so"

# ---------------------------------------------------------------- 3. launcher
say "writing launcher ..."
sed -e "s|__PREFIX__|$PREFIX|g" \
    -e "s|__OPENCODE_DIR__|$OPENCODE_DIR|g" \
    "$SRC_DIR/src/opencode" > "$OPENCODE_DIR/bin/opencode"
chmod 755 "$OPENCODE_DIR/bin/opencode"

case ":$PATH:" in
    *":$OPENCODE_DIR/bin:"*) ;;
    *) warn "$OPENCODE_DIR/bin is not in PATH — add it:"
       warn "  echo 'export PATH=\"$OPENCODE_DIR/bin:\$PATH\"' >> ~/.zshrc" ;;
esac

# ---------------------------------------------------------------- 4. verify
say "verifying ..."
"$OPENCODE_DIR/bin/opencode" --version || die "opencode failed to start"

if [ -n "$SRC_TMP" ]; then rm -rf "$SRC_TMP"; fi

say "done. Run: opencode"
