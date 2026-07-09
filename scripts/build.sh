#!/usr/bin/env bash
#
# Tetris build helper.
#
#   scripts/build.sh macos              Build the macOS desktop app (sandbox off) and install to /Applications
#   scripts/build.sh testflight         Build + package + upload the iOS app to TestFlight
#   scripts/build.sh testflight --bump  Same, but bump the build number (X.Y.Z+N -> +N+1) and commit first
#   scripts/build.sh ipa                Build + package the iOS IPA only (no upload)
#
# TestFlight uploads need an app-specific password for apple@tear.one. Provide it via either:
#   - env var:  ASC_APP_PW=xxxx-xxxx-xxxx-xxxx scripts/build.sh testflight
#   - a file:   scripts/.asc_app_pw   (single line, gitignored)
#
set -euo pipefail

# ---- config ---------------------------------------------------------------
APPLE_ID="apple@tear.one"
ASC_PROVIDER="MYUTW2GF6J"          # Andras Benedek Fodor (individual account)
BUNDLE_ID="one.tear.tetrisz"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$REPO_ROOT/app"
PW_FILE="$REPO_ROOT/scripts/.asc_app_pw"

# ---- helpers --------------------------------------------------------------
c_blue()  { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
c_green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
c_red()   { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }
die()     { c_red "error: $*"; exit 1; }

# Prefer the fvm-pinned Flutter; fall back to plain flutter on PATH.
flutter_cmd() {
  if command -v fvm >/dev/null 2>&1 && [ -d "$APP_DIR/.fvm" ]; then
    echo "fvm flutter"
  elif command -v flutter >/dev/null 2>&1; then
    echo "flutter"
  else
    die "no flutter found (install fvm or flutter)"
  fi
}
FLUTTER="$(flutter_cmd)"

# ---- macOS desktop --------------------------------------------------------
build_macos() {
  c_blue "Building macOS desktop app (release)…"
  cd "$APP_DIR"
  $FLUTTER build macos --release

  local src dest
  src="$(ls -d "$APP_DIR"/build/macos/Build/Products/Release/*.app | head -1)"
  [ -n "$src" ] || die "build produced no .app"
  dest="/Applications/Tetris.app"

  # Sanity: multiplayer needs App Sandbox OFF (see memory: macos-desktop-build).
  if codesign -d --entitlements :- "$src" 2>/dev/null | grep -q '<key>com.apple.security.app-sandbox</key>[[:space:]]*<true/>'; then
    die "App Sandbox is ENABLED on the build — multiplayer will not work. Check macos/Runner/*.entitlements"
  fi

  c_blue "Installing to $dest …"
  osascript -e 'quit app "Tetris"' 2>/dev/null || true
  osascript -e 'quit app "tetris"' 2>/dev/null || true
  rm -rf "$dest"
  cp -R "$src" "$dest"
  xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true

  c_green "Installed $(du -sh "$dest" | cut -f1) -> $dest"
  open "$dest"
  c_green "Launched Tetris.app"
}

# ---- iOS IPA packaging ----------------------------------------------------
# Builds the archive, then packages an App Store IPA by hand. Flutter's own
# export step fails on this machine (expired Xcode Apple ID) and the resulting
# archive is already correctly distribution-signed, so we assemble the IPA
# ourselves — copying Runner.app into Payload/ and building a SwiftSupport/
# folder that contains EXACTLY the swift dylibs embedded in the app (Apple
# rejects both a missing SwiftSupport and any extra dylib).
build_ipa() {
  c_blue "Building iOS archive…"
  cd "$APP_DIR"
  # `flutter build ipa` archives fine but its export step errors out — that's
  # expected; we package from the archive regardless.
  $FLUTTER build ipa || true

  local archive app stage
  archive="$APP_DIR/build/ios/archive/Runner.xcarchive"
  app="$archive/Products/Applications/Runner.app"
  [ -d "$app" ] || die "archive not found at $archive"

  stage="$(mktemp -d)/ipa_build"
  rm -rf "$stage"; mkdir -p "$stage/Payload" "$stage/SwiftSupport/iphoneos"
  cp -R "$app" "$stage/Payload/"

  c_blue "Collecting Swift support dylibs…"
  xcrun swift-stdlib-tool --copy \
    --scan-executable "$stage/Payload/Runner.app/Runner" \
    --scan-folder "$stage/Payload/Runner.app/Frameworks" \
    --platform iphoneos \
    --destination "$stage/SwiftSupport/iphoneos" >/dev/null

  # swift-stdlib-tool over-collects OS-provided dylibs (e.g. libswiftCore).
  # Keep only those actually embedded in Runner.app/Frameworks/.
  local fw="$stage/Payload/Runner.app/Frameworks"
  for f in "$stage/SwiftSupport/iphoneos"/*.dylib; do
    [ -e "$f" ] || continue
    if [ ! -e "$fw/$(basename "$f")" ]; then
      echo "   pruning $(basename "$f") (not embedded)"
      rm -f "$f"
    fi
  done
  echo "   SwiftSupport: $(ls "$stage/SwiftSupport/iphoneos" | tr '\n' ' ')"

  IPA_PATH="$stage/Tetris.ipa"
  # Apple wants SwiftSupport to mirror the embedded swift dylibs EXACTLY:
  # missing while dylibs are embedded -> ITMS-90426, extra dylibs ->
  # ITMS-90429, and present-but-EMPTY -> ITMS-90424 (since iOS 15 targets
  # embed no swift dylibs at all, the folder must be omitted entirely).
  local zip_dirs=(Payload)
  if [ -n "$(ls -A "$stage/SwiftSupport/iphoneos" 2>/dev/null)" ]; then
    zip_dirs+=(SwiftSupport)
  else
    echo "   no embedded swift dylibs -> omitting SwiftSupport entirely"
    rm -rf "$stage/SwiftSupport"
  fi
  ( cd "$stage" && rm -f Tetris.ipa && zip -qry Tetris.ipa "${zip_dirs[@]}" )
  c_green "Packaged $(du -h "$IPA_PATH" | cut -f1) -> $IPA_PATH"
}

# ---- TestFlight upload ----------------------------------------------------
resolve_pw() {
  if [ -n "${ASC_APP_PW:-}" ]; then
    echo "$ASC_APP_PW"
  elif [ -f "$PW_FILE" ]; then
    tr -d '[:space:]' < "$PW_FILE"
  else
    die "no app-specific password. Set ASC_APP_PW or create $PW_FILE"
  fi
}

bump_build_number() {
  local line cur build next
  line="$(grep -E '^version:' "$APP_DIR/pubspec.yaml")"
  cur="${line#version: }"                      # e.g. 1.0.0+9
  build="${cur#*+}"                            # 9
  next="${cur%+*}+$((build + 1))"              # 1.0.0+10
  c_blue "Bumping build number: $cur -> $next"
  # portable in-place edit
  perl -pi -e "s/^version: .*/version: $next/" "$APP_DIR/pubspec.yaml"
  ( cd "$REPO_ROOT" && git add app/pubspec.yaml \
      && git commit -q -m "chore: bump app version to $next" )
  c_green "Committed version bump ($next)"
}

upload_testflight() {
  local pw="$1"
  c_blue "Uploading to TestFlight (provider $ASC_PROVIDER)…"
  xcrun altool --upload-app -f "$IPA_PATH" -t ios \
    -u "$APPLE_ID" -p "$pw" --asc-provider "$ASC_PROVIDER"
  c_green "Upload finished — check App Store Connect / TestFlight for processing."
}

# ---- dispatch -------------------------------------------------------------
cmd="${1:-}"; shift || true
case "$cmd" in
  macos)
    build_macos
    ;;
  ipa)
    build_ipa
    c_green "IPA ready: $IPA_PATH"
    ;;
  testflight)
    pw="$(resolve_pw)"        # resolve before building so we fail fast
    if [ "${1:-}" = "--bump" ]; then bump_build_number; fi
    build_ipa
    upload_testflight "$pw"
    ;;
  *)
    # print only the leading usage block (comments right after the shebang)
    awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
    exit 1
    ;;
esac
