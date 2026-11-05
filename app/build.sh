#!/usr/bin/env bash
# Usage: app/build.sh
# Builds Guardrails.app from this kit and installs it into ~/Applications (GUARDRAILS_APP_DIR overrides).
# Run it from the kit install the owner's commands run from: the app calls bin/guardrails of the kit it was
# built from (the path is written into its Info.plist), never a command found on PATH.
set -euo pipefail
app_dir=$(cd "$(dirname "$0")" && pwd -P)
kit=$(cd "$app_dir/.." && pwd -P)
dest=${GUARDRAILS_APP_DIR:-$HOME/Applications}

swift build -c release --package-path "$app_dir"
bin=$(swift build -c release --package-path "$app_dir" --show-bin-path)

bundle="$app_dir/.build/Guardrails.app"
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$bin/Guardrails" "$bundle/Contents/MacOS/Guardrails"
cp "$app_dir/Resources/AppIcon.icns" "$bundle/Contents/Resources/AppIcon.icns"

xml_escape() {
  local text=$1
  text=${text//&/&amp;}
  text=${text//</&lt;}
  text=${text//>/&gt;}
  printf '%s' "$text"
}
version=$(git -C "$kit" rev-parse --short HEAD)
cat >"$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.agent-guardrails.Guardrails</string>
  <key>CFBundleName</key><string>Guardrails</string>
  <key>CFBundleDisplayName</key><string>Guardrails</string>
  <key>CFBundleExecutable</key><string>Guardrails</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>$(xml_escape "$version")</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>agent-guardrails</string>
  <key>GuardrailsKitPath</key><string>$(xml_escape "$kit")</string>
</dict>
</plist>
PLIST
plutil -lint "$bundle/Contents/Info.plist" >/dev/null
codesign --force --sign - "$bundle"

mkdir -p "$dest"
rm -rf "$dest/Guardrails.app"
cp -R "$bundle" "$dest/Guardrails.app"
printf 'Installed %s/Guardrails.app (kit %s at %s). Open it once; it lives in the menu bar.\n' "$dest" "$kit" "$version"
