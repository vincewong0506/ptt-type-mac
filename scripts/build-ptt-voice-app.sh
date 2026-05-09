#!/usr/bin/env bash
set -euo pipefail

# Build PTT Voice as a standalone .app at dist/PTT Voice.app.
#
# By default this is an incremental build: derived data is preserved at
# $XCODE_DD between runs so a re-run after a small Swift change is fast
# and avoids re-resolving SPM packages (which has been flaky on slow
# networks — "Couldn't update repository submodules"). Pass --clean to
# wipe derived data for a from-scratch build.
#
# All xcodebuild output (thousands of lines of compile / link / resource
# copy) goes to $LOG_FILE. The terminal only sees a handful of milestone
# lines plus errors. This is on purpose: streaming xcodebuild's full
# output through a real terminal can pin Terminal.app or iTerm2 at 100 %
# CPU on macOS and feel like a hang or a crash. Tail the log in a second
# window if you want to watch:  tail -f dist/xcodebuild.log
#
# Why xcodebuild and not `swift build`: only Xcode's pipeline runs
# mlx-swift's PrepareMetalShaders SPM plugin, which produces
# default.metallib inside mlx-swift_Cmlx.bundle. The previous swift-build
# path silently dropped that bundle and MLX init fataled at first launch
# ("Failed to load the default metallib"). Xcode also copies the other
# SPM resource bundles (swift-transformers_Hub, swift-crypto_Crypto) and
# compiles Assets.xcassets / Info.plist for us, so the manual app-bundle
# assembly that used to live here is gone.
#
# Codesigning: when no PTT_VOICE_CODESIGN_IDENTITY env var is set, we
# force ad-hoc signing (CODE_SIGN_IDENTITY="-"). Equivalent to Xcode's
# "Sign to Run Locally" — entitlements are honored, hardened runtime is
# auto-disabled. Don't pass CODE_SIGNING_ALLOWED=NO instead: that
# triggers a linker-only signature that strips entitlements even if
# PTTVoice.entitlements lists them, which silently breaks
# com.apple.security.device.audio-input → the system-microphone PTT
# mode never gets a TCC prompt. The post-build entitlement sanity check
# below catches that regression.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/PTTVoice/PTTVoice.xcodeproj"
SCHEME="PTTVoice"
APP_NAME="PTT Voice"
BUILD_DIR="$ROOT_DIR/dist"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
XCODE_DD="$BUILD_DIR/build"
LOG_FILE="$BUILD_DIR/xcodebuild.log"

# Friendly status output. Color when stdout is a TTY; plain otherwise.
if [[ -t 1 ]]; then
    log()  { printf '\033[0;36m[build]\033[0m %s\n' "$*"; }
    warn() { printf '\033[0;33m[warn]\033[0m  %s\n' "$*" >&2; }
    err()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; }
else
    log()  { printf '[build] %s\n' "$*"; }
    warn() { printf '[warn]  %s\n' "$*" >&2; }
    err()  { printf '[error] %s\n' "$*" >&2; }
fi

usage() {
    cat <<EOF >&2
Usage: $0 [--clean] [--verbose]

  --clean    Wipe derived data ($XCODE_DD) before building. Slower (full
             SPM re-resolve, full recompile) but recovers from poisoned
             cache state.
  --verbose  Mirror xcodebuild output to the terminal as well as the log.
             Useful when debugging a build failure interactively. WARNING:
             output volume may stress slow terminals.

Without flags, this is a fast incremental build. The full xcodebuild
log is always written to $LOG_FILE; tail it in another window to watch.
EOF
}

CLEAN=0
VERBOSE=0
for arg in "$@"; do
    case "$arg" in
        --clean)   CLEAN=1 ;;
        --verbose) VERBOSE=1 ;;
        -h|--help) usage; exit 0 ;;
        *) err "Unknown argument: $arg"; usage; exit 64 ;;
    esac
done

mkdir -p "$BUILD_DIR"
# Always replace the previous output bundle so cp -R below doesn't merge
# stale resources. Derived data is separate and only wiped on --clean.
rm -rf "$APP_DIR"
if [[ $CLEAN -eq 1 ]]; then
    log "--clean: wiping $XCODE_DD"
    rm -rf "$XCODE_DD"
fi

# Ensure the asset catalog's AppIcon set has its PNGs in place. Tracked
# Contents.json lists the slots but the PNGs are generated and not
# checked in, so a fresh checkout would build an .app with the macOS
# default icon if we skipped this.
APPICONSET="$ROOT_DIR/PTTVoice/PTTVoice/Assets.xcassets/AppIcon.appiconset"
if [[ ! -f "$APPICONSET/icon_512x512@2x.png" ]]; then
    log "Generating AppIcon assets…"
    bash "$(dirname "${BASH_SOURCE[0]}")/generate-app-icon.sh" >/dev/null
fi

XCODEBUILD_ARGS=(
    -project "$PROJECT"
    -scheme "$SCHEME"
    -configuration Release
    -derivedDataPath "$XCODE_DD"
    -destination "generic/platform=macOS"
    # -quiet trims the per-file noise (compile / link / cp invocations)
    # while still surfacing real errors and warnings to the log.
    -quiet
    # Apple-Silicon-only single-arch build. Universal Release would also
    # try x86_64, where speech-swift's Float16 casts fail to compile
    # (Float16 is unavailable on macOS x86_64). ONLY_ACTIVE_ARCH alone
    # isn't enough — SPM-built dependencies don't honour it for the
    # package frontends — so we also pin ARCHS and exclude x86_64.
    ONLY_ACTIVE_ARCH=YES
    ARCHS=arm64
    EXCLUDED_ARCHS=x86_64
)

if [[ -n "${PTT_VOICE_CODESIGN_IDENTITY:-}" ]]; then
    log "Signing with PTT_VOICE_CODESIGN_IDENTITY=\"$PTT_VOICE_CODESIGN_IDENTITY\""
    XCODEBUILD_ARGS+=(CODE_SIGN_IDENTITY="$PTT_VOICE_CODESIGN_IDENTITY")
else
    log "Signing ad-hoc (no PTT_VOICE_CODESIGN_IDENTITY set)"
    XCODEBUILD_ARGS+=(CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO)
fi

log "Running xcodebuild (full log: $LOG_FILE)"
# Reset the log so a previous run's tail doesn't get tangled into this
# run's "last N lines on failure" output.
: > "$LOG_FILE"
if [[ $VERBOSE -eq 1 ]]; then
    # Tee mode: mirror to terminal AND log. Use this when debugging.
    if ! xcodebuild "${XCODEBUILD_ARGS[@]}" build 2>&1 | tee "$LOG_FILE"; then
        err "xcodebuild failed; full log: $LOG_FILE"
        exit 1
    fi
else
    # Quiet mode (default): output only goes to the log file, so a slow
    # terminal can't be overwhelmed.
    if ! xcodebuild "${XCODEBUILD_ARGS[@]}" build > "$LOG_FILE" 2>&1; then
        err "xcodebuild failed. Last 40 lines of $LOG_FILE:"
        tail -n 40 "$LOG_FILE" >&2
        err "Full log: $LOG_FILE"
        exit 1
    fi
fi
log "xcodebuild OK"

BUILT_APP="$XCODE_DD/Build/Products/Release/PTTVoice.app"
if [[ ! -d "$BUILT_APP" ]]; then
    err "xcodebuild reported success but $BUILT_APP not found"
    exit 1
fi

cp -R "$BUILT_APP" "$APP_DIR"

# Sanity check: confirm MLX's metal library actually made it into the
# bundle. If this ever regresses we want to fail loud here, not at the
# user's first launch with a fatalError.
if ! find "$APP_DIR" -name 'default.metallib' -print -quit | grep -q .; then
    err "$APP_DIR has no default.metallib — MLX will fail at runtime"
    exit 1
fi

# Sanity check: confirm the audio-input entitlement made it into the
# signed binary. Without it, AVAudioEngine.inputNode is blocked under
# hardened runtime and the system-mic PTT mode silently dies. A
# linker-only signature (e.g. CODE_SIGNING_ALLOWED=NO) would pass the
# metallib check but fail this one — that's the regression to catch.
if ! codesign -d --entitlements - "$APP_DIR" 2>&1 | grep -q "com.apple.security.device.audio-input"; then
    err "$APP_DIR is missing com.apple.security.device.audio-input entitlement"
    err "(the system-microphone PTT mode will not work)"
    exit 1
fi

# Friendly summary to terminal. The bare path on the last line is still
# the script's output contract for anything piping us.
APP_SIZE=$(du -sh "$APP_DIR" | cut -f1)
log "Built $APP_DIR ($APP_SIZE)"
echo "$APP_DIR"
