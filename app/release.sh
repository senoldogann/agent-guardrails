#!/usr/bin/env bash
# Usage: app/release.sh   (the owner, on macOS, after VERSION's release exists on GitHub)
# Builds Guardrails.app for other Macs and attaches it to the GitHub release of VERSION:
#   1. builds with a Developer ID identity (required here) and the kit path ~/.local/share/agent-guardrails,
#      where README's install puts the kit, so the app finds the kit on any Mac that followed it;
#   2. notarizes it with the notarytool keychain profile GUARDRAILS_NOTARY_PROFILE (default guardrails-notary,
#      stored once with `xcrun notarytool store-credentials`), staples the ticket and checks Gatekeeper accepts it;
#   3. uploads Guardrails-<VERSION>.zip to the release v<VERSION>, replacing an earlier upload.
set -euo pipefail
app_dir=$(cd "$(dirname "$0")" && pwd -P)
kit=$(cd "$app_dir/.." && pwd -P)
profile=${GUARDRAILS_NOTARY_PROFILE:-guardrails-notary}
release=$(<"$kit/VERSION")
tag="v$release"
repo=$(git -C "$kit" remote get-url origin | sed -E 's#^.*github\.com[:/]##; s#\.git$##')

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

[[ $(uname) == Darwin ]] || die "release.sh builds the macOS app; run it on a Mac"
security find-identity -v -p codesigning | grep -F '"Developer ID Application: ' >/dev/null ||
  die "no Developer ID Application identity in the keychain; a release for other Macs needs one"
gh release view "$tag" -R "$repo" >/dev/null 2>&1 || die "$repo has no release $tag yet; merge the VERSION bump first"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# A literal ~: the app expands it on the Mac it runs on.
# shellcheck disable=SC2088
GUARDRAILS_APP_DIR="$work" GUARDRAILS_APP_KIT_PATH="~/.local/share/agent-guardrails" "$app_dir/build.sh"
app="$work/Guardrails.app"
zip="$work/Guardrails-$release.zip"

ditto -c -k --keepParent "$app" "$zip"
xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait ||
  die "notarization failed; see the log with: xcrun notarytool log <submission id> --keychain-profile $profile"
xcrun stapler staple "$app"
spctl --assess --type execute -vv "$app"
rm "$zip"
ditto -c -k --keepParent "$app" "$zip"
gh release upload "$tag" "$zip" -R "$repo" --clobber
printf 'Uploaded %s to %s %s\n' "${zip##*/}" "$repo" "$tag"
