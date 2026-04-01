#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRAND_CONFIG="$ROOT/macos/GlossolaliaBrand.xcconfig"
RELEASE_BRANCH="${RELEASE_BRANCH:-glossolalia}"
cleanup_dir=""
cd "$ROOT"

die() {
  echo "error: $*" >&2
  exit 1
}

brand_setting() {
  awk -F= -v key="$1" '
    $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
      value = $2
      sub(/^[[:space:]]*/, "", value)
      sub(/[[:space:]]*$/, "", value)
      print value
      exit
    }
  ' "$BRAND_CONFIG"
}

APP_NAME="$(brand_setting GLOSSOLALIA_APP_PRODUCT_NAME)"
BUNDLE_ID="$(brand_setting GLOSSOLALIA_BUNDLE_ID)"
EXECUTABLE_NAME="$(brand_setting GLOSSOLALIA_EXECUTABLE_NAME)"
PRODUCT_SLUG="glossolalia"
MINIMUM_SYSTEM_VERSION="13.0"
[[ -n "$APP_NAME" && -n "$BUNDLE_ID" && -n "$EXECUTABLE_NAME" ]] ||
  die "product identity is incomplete in $BRAND_CONFIG"

cleanup() {
  if [[ -n "$cleanup_dir" && -d "$cleanup_dir" ]]; then
    rm -rf "$cleanup_dir"
  fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Prepare, verify, and optionally publish a standalone macOS release.

Usage:
  ./scripts/release-macos-local.sh preflight <version>
  ./scripts/release-macos-local.sh prepare <version>
  ./scripts/release-macos-local.sh verify <version>
  ./scripts/release-macos-local.sh publish <version> [--final]

Commands:
  preflight  Check the release checkout, Developer ID identity, and notary profile.
  prepare    Build, sign, notarize, staple, package, checksum, and verify artifacts.
  verify     Repeat artifact, signature, Gatekeeper, and notarization checks.
  publish    Tag the verified commit and create a draft GitHub release.
             Pass --final to make it public immediately.

Artifacts are written to dist/releases/v<version>. Product identity is read
from macos/GlossolaliaBrand.xcconfig.

Environment:
  CODESIGN_IDENTITY  Required by preflight and prepare
  NOTARY_PROFILE     Required by preflight and prepare
EOF
}

require_tools() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null || die "missing required tool: $tool"
  done
}

set_paths() {
  VERSION="$1"
  TAG="v$VERSION"
  RELEASE_DIR="$ROOT/dist/releases/$TAG"
  MANIFEST="$RELEASE_DIR/release.env"
  APP="$ROOT/macos/build/Release/$APP_NAME.app"
  DSYM_SOURCE="$ROOT/macos/build/Release/$APP_NAME.app.dSYM"
  DMG="$RELEASE_DIR/$APP_NAME.dmg"
  ZIP="$RELEASE_DIR/$PRODUCT_SLUG-macos-universal.zip"
  DSYM_ZIP="$RELEASE_DIR/$PRODUCT_SLUG-macos-universal-dsym.zip"
  CHECKSUMS="$RELEASE_DIR/SHA256SUMS"
}

validate_version() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must follow X.Y.Z"
}

validate_checkout() {
  local branch
  [[ -z "$(git status --short)" ]] || die "worktree must be clean"
  branch="$(git branch --show-current)"
  [[ "$branch" == "$RELEASE_BRANCH" ]] ||
    die "release must run from $RELEASE_BRANCH; current branch: $branch"
}

validate_signing_setup() {
  : "${CODESIGN_IDENTITY:?set CODESIGN_IDENTITY to your Developer ID Application identity}"
  : "${NOTARY_PROFILE:?set NOTARY_PROFILE to your stored notarytool profile name}"
  [[ "$CODESIGN_IDENTITY" == "Developer ID Application:"* ]] ||
    die "CODESIGN_IDENTITY must be a Developer ID Application identity"
  security find-identity -v -p codesigning |
    grep -F -- "\"$CODESIGN_IDENTITY\"" >/dev/null ||
    die "Developer ID identity is not installed or valid: $CODESIGN_IDENTITY"
  echo "validating notary profile: $NOTARY_PROFILE"
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null ||
    die "notary profile is unavailable or invalid: $NOTARY_PROFILE"
}

preflight() {
  require_tools git grep security xcrun
  validate_checkout
  validate_signing_setup
  echo "release preflight passed"
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null
}

expect_plist() {
  local actual
  actual="$(plist_value "$1" "$2")" || die "missing Info.plist key: $2"
  [[ "$actual" == "$3" ]] ||
    die "unexpected $2: expected '$3', found '$actual'"
}

verify_app() {
  local app="$1"
  local version="$2"
  local commit_short="$3"
  local team_id="$4"
  local signature entitlements actual_team archs arch key

  [[ -d "$app" ]] || die "app bundle not found: $app"
  [[ -x "$app/Contents/MacOS/$EXECUTABLE_NAME" ]] ||
    die "release executable not found: $EXECUTABLE_NAME"
  [[ -f "$app/Contents/Resources/Assets.car" ]] ||
    die "compiled asset catalog is missing"

  expect_plist "$app" CFBundleDisplayName "$APP_NAME"
  expect_plist "$app" CFBundleIdentifier "$BUNDLE_ID"
  expect_plist "$app" CFBundleExecutable "$EXECUTABLE_NAME"
  expect_plist "$app" CFBundleShortVersionString "$version"
  expect_plist "$app" GhosttyCommit "$commit_short"
  expect_plist "$app" LSMinimumSystemVersion "$MINIMUM_SYSTEM_VERSION"
  expect_plist "$app" GlossolaliaUpdateStableFeedURL ""
  expect_plist "$app" GlossolaliaUpdateTipFeedURL ""
  expect_plist "$app" GlossolaliaReleaseNotesURLTemplate \
    "https://github.com/hzoo/glossolalia/releases/tag/v$version"
  for key in SUPublicEDKey SUFeedURL SUEnableAutomaticChecks; do
    if plist_value "$app" "$key" >/dev/null; then
      die "unexpected updater key in release Info.plist: $key"
    fi
  done

  archs="$(lipo -archs "$app/Contents/MacOS/$EXECUTABLE_NAME")"
  for arch in arm64 x86_64; do
    grep -qw "$arch" <<<"$archs" || die "release executable is missing $arch"
  done

  codesign --verify --deep --strict --verbose=2 "$app"
  signature="$(codesign -dvvv "$app" 2>&1)"
  grep -q '^Authority=Developer ID Application:' <<<"$signature" ||
    die "app is not signed with a Developer ID Application certificate"
  grep -q 'runtime' <<<"$signature" || die "app is missing hardened runtime"
  actual_team="$(sed -n 's/^TeamIdentifier=//p' <<<"$signature")"
  [[ "$actual_team" == "$team_id" ]] || die "app TeamIdentifier mismatch"

  entitlements="$(codesign -d --entitlements - "$app" 2>&1)"
  if grep -q 'com.apple.security.get-task-allow' <<<"$entitlements"; then
    die "release app contains the debug get-task-allow entitlement"
  fi
  if grep -q 'com.apple.security.cs.disable-library-validation' <<<"$entitlements"; then
    die "release app disables library validation"
  fi
}

write_manifest() {
  {
    printf 'RELEASE_VERSION=%q\n' "$VERSION"
    printf 'RELEASE_COMMIT=%q\n' "$1"
    printf 'RELEASE_COMMIT_SHORT=%q\n' "$2"
    printf 'RELEASE_TEAM_ID=%q\n' "$3"
  } >"$MANIFEST"
}

load_manifest() {
  [[ -f "$MANIFEST" ]] || die "release manifest not found; run prepare first: $MANIFEST"
  unset RELEASE_VERSION RELEASE_COMMIT RELEASE_COMMIT_SHORT RELEASE_TEAM_ID
  # prepare generates this local file with shell-escaped values.
  source "$MANIFEST"
  [[ "${RELEASE_VERSION:-}" == "$VERSION" ]] || die "release manifest version mismatch"
  [[ -n "${RELEASE_COMMIT:-}" && -n "${RELEASE_COMMIT_SHORT:-}" ]] ||
    die "release manifest has no commit"
  [[ -n "${RELEASE_TEAM_ID:-}" ]] || die "release manifest has no TeamIdentifier"
}

verify_release() {
  local dmg_signature dmg_team
  require_tools codesign hdiutil lipo shasum spctl xcrun unzip
  [[ -x /usr/libexec/PlistBuddy ]] || die "PlistBuddy is unavailable"
  load_manifest
  [[ -f "$DMG" && -f "$ZIP" && -f "$CHECKSUMS" ]] ||
    die "release artifacts are incomplete in $RELEASE_DIR"

  (cd "$RELEASE_DIR" && shasum -a 256 -c "$(basename "$CHECKSUMS")")
  unzip -tq "$ZIP" >/dev/null
  [[ ! -f "$DSYM_ZIP" ]] || unzip -tq "$DSYM_ZIP" >/dev/null

  verify_app "$APP" "$VERSION" "$RELEASE_COMMIT_SHORT" "$RELEASE_TEAM_ID"
  spctl --assess --type execute --verbose=4 "$APP"
  xcrun stapler validate "$APP"

  hdiutil verify "$DMG" >/dev/null
  codesign --verify --verbose=2 "$DMG"
  dmg_signature="$(codesign -dvvv "$DMG" 2>&1)"
  grep -q '^Authority=Developer ID Application:' <<<"$dmg_signature" ||
    die "DMG is not signed with a Developer ID Application certificate"
  dmg_team="$(sed -n 's/^TeamIdentifier=//p' <<<"$dmg_signature")"
  [[ "$dmg_team" == "$RELEASE_TEAM_ID" ]] || die "DMG TeamIdentifier mismatch"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"
  xcrun stapler validate "$DMG"
  echo "release verification passed: $RELEASE_DIR"
}

prepare_release() {
  local build commit commit_short team_id sparkle_root component
  local release_notes compare_url commit_url
  local -a checksum_files

  require_tools codesign ditto git hdiutil ln security shasum spctl xcodebuild xcrun zig
  [[ -x /usr/libexec/PlistBuddy ]] || die "PlistBuddy is unavailable"
  preflight
  [[ ! -e "$RELEASE_DIR" ]] ||
    die "release directory already exists; remove it before rebuilding: $RELEASE_DIR"

  build="$(git rev-list --count HEAD)"
  commit="$(git rev-parse HEAD)"
  commit_short="$(git rev-parse --short HEAD)"
  release_notes="https://github.com/hzoo/glossolalia/releases/tag/$TAG"
  compare_url="https://github.com/hzoo/glossolalia/compare/{current}...{new}"
  commit_url="https://github.com/hzoo/glossolalia/commit/{new}"

  echo "building GhosttyKit..."
  zig build -Doptimize=ReleaseFast -Demit-macos-app=false -Dversion-string="$VERSION"

  echo "building $APP_NAME.app..."
  rm -rf "$APP" "$DSYM_SOURCE"
  xcodebuild \
    -project "$ROOT/macos/Ghostty.xcodeproj" \
    -target Ghostty \
    -configuration Release \
    GLOSSOLALIA_MARKETING_VERSION="$VERSION" \
    GLOSSOLALIA_RELEASE_NOTES_URL_TEMPLATE="$release_notes" \
    GLOSSOLALIA_COMPARE_URL_TEMPLATE="$compare_url" \
    GLOSSOLALIA_COMMIT_URL_TEMPLATE="$commit_url" \
    GLOSSOLALIA_UPDATE_STABLE_FEED_URL="" \
    GLOSSOLALIA_UPDATE_TIP_FEED_URL="" \
    MACOSX_DEPLOYMENT_TARGET="$MINIMUM_SYSTEM_VERSION" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    COMPILATION_CACHE_KEEP_CAS_DIRECTORY=YES \
    build
  [[ -d "$APP" ]] || die "expected app bundle not found: $APP"

  /usr/libexec/PlistBuddy -c "Set :GhosttyCommit $commit_short" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
  for component in SUEnableAutomaticChecks SUPublicEDKey SUFeedURL; do
    /usr/libexec/PlistBuddy -c "Delete :$component" "$APP/Contents/Info.plist" 2>/dev/null || true
  done

  echo "signing app bundle..."
  sparkle_root="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  for component in \
    "$sparkle_root/XPCServices/Downloader.xpc" \
    "$sparkle_root/XPCServices/Installer.xpc" \
    "$sparkle_root/Autoupdate" \
    "$sparkle_root/Updater.app" \
    "$APP/Contents/Frameworks/Sparkle.framework" \
    "$APP/Contents/PlugIns/DockTilePlugin.plugin"; do
    [[ -e "$component" ]] || die "signing component not found: $component"
    codesign --force --verbose --sign "$CODESIGN_IDENTITY" --options runtime --timestamp "$component"
  done
  codesign \
    --force --verbose --sign "$CODESIGN_IDENTITY" --options runtime --timestamp \
    --entitlements "$ROOT/macos/Ghostty.entitlements" "$APP"

  team_id="$(sed -n 's/^TeamIdentifier=//p' < <(codesign -dvvv "$APP" 2>&1))"
  [[ -n "$team_id" && "$team_id" != "not set" ]] || die "signed app has no TeamIdentifier"
  verify_app "$APP" "$VERSION" "$commit_short" "$team_id"

  mkdir -p "$RELEASE_DIR"
  cleanup_dir="$(mktemp -d "${TMPDIR:-/tmp}/${PRODUCT_SLUG}-dmg.XXXXXX")"
  ditto "$APP" "$cleanup_dir/$APP_NAME.app"
  ln -s /Applications "$cleanup_dir/Applications"
  hdiutil create -volname "$APP_NAME" -srcfolder "$cleanup_dir" -format UDZO "$DMG"
  rm -rf "$cleanup_dir"
  cleanup_dir=""
  codesign --force --verbose --sign "$CODESIGN_IDENTITY" --timestamp "$DMG"

  echo "notarizing DMG..."
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler staple "$APP"

  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
  checksum_files=("$(basename "$DMG")" "$(basename "$ZIP")")
  if [[ -d "$DSYM_SOURCE" ]]; then
    ditto -c -k --sequesterRsrc --keepParent "$DSYM_SOURCE" "$DSYM_ZIP"
    checksum_files+=("$(basename "$DSYM_ZIP")")
  fi
  write_manifest "$commit" "$commit_short" "$team_id"
  (cd "$RELEASE_DIR" && shasum -a 256 "${checksum_files[@]}" >"$(basename "$CHECKSUMS")")

  verify_release
  echo "release prepared; no tag or GitHub release was created"
}

publish_release() {
  local final="$1"
  local current remote tag_commit
  local -a assets options

  require_tools gh git
  validate_checkout
  verify_release
  current="$(git rev-parse HEAD)"
  [[ "$current" == "$RELEASE_COMMIT" ]] ||
    die "release artifacts were built from $RELEASE_COMMIT, not current HEAD"
  gh auth status >/dev/null || die "gh is not authenticated"
  git fetch --quiet origin "$RELEASE_BRANCH"
  remote="$(git rev-parse "origin/$RELEASE_BRANCH")"
  [[ "$remote" == "$current" ]] || {
    echo "publish the reviewed stack first:" >&2
    echo "  git push --force-with-lease origin $RELEASE_BRANCH" >&2
    die "origin/$RELEASE_BRANCH does not match the release commit"
  }

  if git show-ref --verify --quiet "refs/tags/$TAG"; then
    tag_commit="$(git rev-list -n 1 "$TAG")"
    [[ "$tag_commit" == "$current" ]] || die "local tag $TAG points to another commit"
  else
    git tag -a "$TAG" -m "$APP_NAME $TAG"
  fi
  gh release view "$TAG" >/dev/null 2>&1 && die "GitHub release already exists: $TAG"
  git push origin "$TAG"

  assets=("$DMG" "$ZIP" "$CHECKSUMS")
  [[ ! -f "$DSYM_ZIP" ]] || assets+=("$DSYM_ZIP")
  options=(--verify-tag --title "$APP_NAME $TAG" --generate-notes --fail-on-no-commits)
  [[ "$final" == "1" ]] || options+=(--draft)
  gh release create "$TAG" "${assets[@]}" "${options[@]}"
  [[ "$final" == "1" ]] && echo "public GitHub release created: $TAG" ||
    echo "draft GitHub release created: $TAG"
}

command_name="${1:-}"
version="${2:-}"
case "$command_name" in
  help|--help|-h)
    usage
    exit 0
    ;;
  preflight|prepare|verify)
    [[ $# -eq 2 ]] || { usage >&2; exit 1; }
    ;;
  publish)
    [[ $# -eq 2 || ( $# -eq 3 && "$3" == "--final" ) ]] ||
      { usage >&2; exit 1; }
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac

validate_version "$version"
set_paths "$version"
case "$command_name" in
  preflight) preflight ;;
  prepare) prepare_release ;;
  verify) verify_release ;;
  publish) publish_release "$([[ "${3:-}" == "--final" ]] && echo 1 || echo 0)" ;;
esac
