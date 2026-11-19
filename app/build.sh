#!/usr/bin/env bash
# Usage: app/build.sh
# Builds Guardrails.app from this kit and installs it into ~/Applications (GUARDRAILS_APP_DIR overrides).
# Run it from the kit install the owner's commands run from: the app calls bin/guardrails of the kit it was
# built from (the path is written into its Info.plist; GUARDRAILS_APP_KIT_PATH overrides it, and a leading ~
# is expanded when the app starts), never a command found on PATH.
# Test builds: GUARDRAILS_APP_BUNDLE_ID gives the copy its own bundle id, so its settings, notification
# permission and window state stay apart from the installed app and both can run at once.
# Signing: GUARDRAILS_SIGN_IDENTITY names the codesign identity. Unset, the keychain's "Developer ID
# Application" identity is used (hardened runtime, secure timestamp); with none the app is signed ad hoc and
# runs on this Mac only. Two Developer ID identities need GUARDRAILS_SIGN_IDENTITY to pick one.
set -euo pipefail
app_dir=$(cd "$(dirname "$0")" && pwd -P)
kit=$(cd "$app_dir/.." && pwd -P)
dest=${GUARDRAILS_APP_DIR:-$HOME/Applications}
app_kit_path=${GUARDRAILS_APP_KIT_PATH:-$kit}
bundle_id=${GUARDRAILS_APP_BUNDLE_ID:-dev.agent-guardrails.Guardrails}
identity=${GUARDRAILS_SIGN_IDENTITY:-}
if [[ -z $identity ]]; then
  identities=$(security find-identity -v -p codesigning | sed -nE 's/^ *[0-9]+\) [0-9A-F]{40} "(Developer ID Application: [^"]+)"$/\1/p')
  if [[ $(grep -c . <<<"$identities") -gt 1 ]]; then
    printf 'error: several Developer ID Application identities; set GUARDRAILS_SIGN_IDENTITY to one of:\n%s\n' "$identities" >&2
    exit 1
  fi
  identity=$identities
fi

swift build -c release --package-path "$app_dir"
bin=$(swift build -c release --package-path "$app_dir" --show-bin-path)

bundle="$app_dir/.build/Guardrails.app"
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$bin/Guardrails" "$bundle/Contents/MacOS/Guardrails"
cp "$app_dir/Resources/AppIcon.icns" "$bundle/Contents/Resources/AppIcon.icns"
# The asset catalog holds the app's accent color: a neutral gray for selections instead of the system blue.
xcrun actool "$app_dir/Resources/Assets.xcassets" --compile "$bundle/Contents/Resources" \
  --platform macosx --minimum-deployment-target 26.0 --output-format human-readable-text \
  --output-partial-info-plist "$app_dir/.build/assets-info.plist" >/dev/null

xml_escape() {
  local text=$1
  text=${text//&/&amp;}
  text=${text//</&lt;}
  text=${text//>/&gt;}
  printf '%s' "$text"
}
version=$(git -C "$kit" rev-parse --short HEAD)
release=$(<"$kit/VERSION")
cat >"$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$(xml_escape "$bundle_id")</string>
  <key>CFBundleName</key><string>Guardrails</string>
  <key>CFBundleDisplayName</key><string>Guardrails</string>
  <key>CFBundleExecutable</key><string>Guardrails</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$(xml_escape "$release")</string>
  <key>CFBundleVersion</key><string>$(xml_escape "$version")</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAccentColorName</key><string>AccentColor</string>
  <key>NSHumanReadableCopyright</key><string>agent-guardrails</string>
  <key>GuardrailsKitPath</key><string>$(xml_escape "$app_kit_path")</string>
</dict>
</plist>
PLIST
plutil -lint "$bundle/Contents/Info.plist" >/dev/null
if [[ -n $identity ]]; then
  codesign --force --options runtime --timestamp --sign "$identity" "$bundle"
  signed_with=$identity
else
  codesign --force --sign - "$bundle"
  signed_with="ad hoc (no Developer ID Application identity in the keychain; runs on this Mac only)"
fi
codesign --verify --strict "$bundle"

mkdir -p "$dest"
rm -rf "$dest/Guardrails.app"
cp -R "$bundle" "$dest/Guardrails.app"
printf 'Installed %s/Guardrails.app (kit %s %s at %s, signed %s). Open it once; it lives in the menu bar.\n' \
  "$dest" "$app_kit_path" "$release" "$version" "$signed_with"
