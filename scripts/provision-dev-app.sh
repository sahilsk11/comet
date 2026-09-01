#!/usr/bin/env bash
# Build this worktree as an isolated, side-by-side macOS app.
#
# The stable /Applications/Zeron.app is never read, modified, or replaced.
# Every generated app gets a unique bundle id, data directory, IPC port, and
# internal worktree directory so several variants can run concurrently without
# sharing engine locks or mutable state. Development variants intentionally use
# the stable registered WorkOS loopback callback port by default; sign them in
# one at a time, then run them concurrently. --callback-port remains available
# when a WorkOS wildcard redirect has been configured.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME=""
INSTALL_ROOT="${ZERON_DEV_APP_ROOT:-$HOME/Applications/Zeron Dev}"
ICON_SOURCE=""
PROFILE="debug"
OPEN_APP=true
IPC_PORT=""
CALLBACK_PORT=""
DATA_DIR=""
HARNESS=""

usage() {
  printf '%s\n' \
    'Build this worktree as an isolated, side-by-side macOS app.' \
    'The stable Zeron installation is never modified.'
  printf '\nUsage: %s [options]\n\n' "$0"
  printf '%s\n' \
    '  --name NAME          Full app name (default: derived from the git branch)' \
    '  --icon PATH          PNG or ICNS icon (Hamilton has dedicated artwork)' \
    '  --install-root PATH  App destination root' \
    '  --data-dir PATH      Isolated app data directory' \
    '  --ipc-port PORT      Engine IPC port' \
    '  --callback-port PORT Login callback port (default: registered 27641)' \
    '  --harness ID         Default harness, such as codex or hamilton' \
    '  --release            Build the release profile instead of debug' \
    '  --no-open            Provision without launching the app' \
    '  -h, --help           Show this help'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) APP_NAME="${2:?--name requires a value}"; shift 2 ;;
    --icon) ICON_SOURCE="${2:?--icon requires a value}"; shift 2 ;;
    --install-root) INSTALL_ROOT="${2:?--install-root requires a value}"; shift 2 ;;
    --data-dir) DATA_DIR="${2:?--data-dir requires a value}"; shift 2 ;;
    --ipc-port) IPC_PORT="${2:?--ipc-port requires a value}"; shift 2 ;;
    --callback-port) CALLBACK_PORT="${2:?--callback-port requires a value}"; shift 2 ;;
    --harness) HARNESS="${2:?--harness requires a value}"; shift 2 ;;
    --release) PROFILE="release"; shift ;;
    --no-open) OPEN_APP=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'development app provisioning currently requires macOS\n' >&2
  exit 1
fi

branch="$(git -C "$ROOT" branch --show-current 2>/dev/null || true)"
branch="${branch#codex/}"
if [[ -z "$branch" ]]; then
  branch="$(git -C "$ROOT" rev-parse --short HEAD)"
fi
if [[ -z "$APP_NAME" ]]; then
  readable="$(printf '%s' "$branch" | tr '_-' '  ' | awk '{ for (i=1; i<=NF; i++) { $i=toupper(substr($i,1,1)) substr($i,2) } } 1')"
  APP_NAME="Zeron Dev — $readable"
fi

if [[ -z "${APP_NAME// }" || "$APP_NAME" == "Zeron" ]]; then
  printf 'refusing to provision an empty name or overwrite the stable Zeron identity\n' >&2
  exit 1
fi

if [[ "$APP_NAME" == "Hamilton" ]]; then
  if [[ "$branch" != "main" ]]; then
    printf 'Hamilton is reserved for a clean main checkout; name this worktree "Hamilton Fork ..."\n' >&2
    exit 1
  fi
  if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
    printf 'Hamilton is reserved for a clean main checkout; commit or discard worktree changes first\n' >&2
    exit 1
  fi
  if [[ "$HARNESS" != "hamilton" ]]; then
    printf 'the stable Hamilton app must use --harness hamilton\n' >&2
    exit 1
  fi
fi

slug="$(printf '%s' "$APP_NAME" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
if [[ -z "$slug" ]]; then
  printf 'app name must contain at least one letter or number\n' >&2
  exit 1
fi
checksum="$(printf '%s' "$ROOT|$APP_NAME" | cksum | awk '{print $1}')"
instance_id="$slug-$checksum"
bundle_id="sh.zeron.dev.$slug.$checksum"

if [[ -z "$IPC_PORT" ]]; then
  IPC_PORT="$((32000 + checksum % 9000))"
fi
if [[ -z "$CALLBACK_PORT" ]]; then
  # WorkOS validates redirect URIs before authentication. The production
  # client already permits Zeron's native loopback callback on 27641, while
  # fork-specific ports require a dashboard wildcard we do not control.
  CALLBACK_PORT="27641"
fi
if [[ -z "$DATA_DIR" ]]; then
  DATA_DIR="$HOME/.zeron-dev/$instance_id"
fi

for port in "$IPC_PORT" "$CALLBACK_PORT"; do
  if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1024 || port > 65535 )); then
    printf 'invalid port: %s\n' "$port" >&2
    exit 2
  fi
done

case "$HARNESS" in
  ""|claude-code|mock|codex|cursor|grok|hermes|pi|hamilton|opencode) ;;
  *) printf 'unsupported harness id: %s\n' "$HARNESS" >&2; exit 2 ;;
esac

APP_DIR="$INSTALL_ROOT/$APP_NAME.app"
case "$APP_DIR" in
  /Applications/Zeron.app|"$HOME/Applications/Zeron.app")
    printf 'refusing to replace the stable Zeron app\n' >&2
    exit 1
    ;;
esac

mkdir -p "$INSTALL_ROOT"
command -v cargo >/dev/null 2>&1 || PATH="$HOME/.cargo/bin:$PATH"

build_args=(build -p zeron)
if [[ "$PROFILE" == "release" ]]; then
  build_args+=(--release)
fi
(
  cd "$ROOT"
  cargo "${build_args[@]}"
)
target_dir="$(cd "$ROOT" && cargo metadata --format-version=1 --no-deps | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')"
binary="$target_dir/$PROFILE/zeron"
if [[ ! -x "$binary" ]]; then
  printf 'built binary not found: %s\n' "$binary" >&2
  exit 1
fi

stage_root="$(mktemp -d "$INSTALL_ROOT/.zeron-dev-app.XXXXXX")"
trap 'rm -rf "$stage_root"' EXIT
stage_app="$stage_root/$APP_NAME.app"
mkdir -p "$stage_app/Contents/MacOS" "$stage_app/Contents/Resources"
install -m 755 "$binary" "$stage_app/Contents/MacOS/zeron-bin"

version="$(grep -m1 '^version' "$ROOT/Cargo.toml" | sed 's/.*"\(.*\)".*/\1/')"
sed "s/__VERSION__/$version/" "$ROOT/dist/macos/Info.plist" >"$stage_app/Contents/Info.plist"
plist="$stage_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable zeron" "$plist"
/usr/libexec/PlistBuddy -c "Add :ZeronDevVariant bool true" "$plist"
/usr/libexec/PlistBuddy -c "Add :ZeronInstanceId string $instance_id" "$plist"

python3 - "$stage_app/Contents/MacOS/zeron" "$DATA_DIR" "$IPC_PORT" "$CALLBACK_PORT" "$APP_NAME" "$bundle_id" "$HARNESS" <<'PY'
import shlex
import sys

path, data_dir, ipc_port, callback_port, app_name, bundle_id, harness = sys.argv[1:]
exports = {
    "ZERON_DATA_DIR": data_dir,
    "ZERON_WORKTREES_DIR": f"{data_dir}/worktrees",
    "ZERON_IPC_PORT": ipc_port,
    "ZERON_CALLBACK_PORT": callback_port,
    "ZERON_DEVICE_NAME": app_name,
    "ZERON_APP_NAME": app_name,
    "ZERON_BUNDLE_ID": bundle_id,
    "ZERON_DEV_VARIANT": "1",
}
if harness:
    exports["ZERON_HARNESS"] = harness
lines = ["#!/bin/zsh", "set -euo pipefail"]
for key, value in exports.items():
    lines.append(f"export {key}={shlex.quote(value)}")
lines.extend(['script_dir="${0:A:h}"', 'exec "$script_dir/zeron-bin" "$@"'])
with open(path, "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines) + "\n")
PY
chmod 755 "$stage_app/Contents/MacOS/zeron"

if [[ -z "$ICON_SOURCE" ]]; then
  if [[ "$HARNESS" == "hamilton" ]]; then
    ICON_SOURCE="$ROOT/dist/macos/hamilton-icon-1024.png"
  else
    ICON_SOURCE="$ROOT/dist/macos/icon-1024.png"
  fi
fi
if [[ ! -f "$ICON_SOURCE" ]]; then
  printf 'icon not found: %s\n' "$ICON_SOURCE" >&2
  exit 1
fi
if [[ "$ICON_SOURCE" == *.icns ]]; then
  cp "$ICON_SOURCE" "$stage_app/Contents/Resources/zeron.icns"
else
  iconset="$stage_root/zeron.iconset"
  mkdir -p "$iconset"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SOURCE" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    retina="$((size * 2))"
    sips -z "$retina" "$retina" "$ICON_SOURCE" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$iconset" -o "$stage_app/Contents/Resources/zeron.icns"
fi

codesign --deep --force --sign - "$stage_app" >/dev/null
if [[ -e "$APP_DIR" ]]; then
  if pgrep -f "$APP_DIR/Contents/MacOS/zeron-bin" >/dev/null 2>&1; then
    printf 'refusing to replace a running development app: %s\n' "$APP_DIR" >&2
    exit 1
  fi
  rm -rf "$APP_DIR"
fi
mv "$stage_app" "$APP_DIR"

printf 'Provisioned %s\n' "$APP_DIR"
printf '  bundle:   %s\n' "$bundle_id"
printf '  data:     %s\n' "$DATA_DIR"
printf '  ipc:      %s\n' "$IPC_PORT"
printf '  callback: %s\n' "$CALLBACK_PORT"
printf '  source:   %s (%s)\n' "$ROOT" "${branch:-detached}"
if [[ -n "$HARNESS" ]]; then
  printf '  harness:  %s\n' "$HARNESS"
fi

if $OPEN_APP; then
  open -n "$APP_DIR"
fi
