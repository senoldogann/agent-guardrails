#!/usr/bin/env bash
# Usage: scripts/check-vendored-pyyaml.sh
# Confirms that the YAML parser the workflow check runs (the template's .agent/workflow/guardrails_pyyaml/) is
# the pinned PyYAML release, unchanged: downloads the sdist named in scripts/vendored-pyyaml/requirements.txt,
# verifies its SHA-256, and compares every vendored file with the release byte for byte. Only the kit's own
# __init__.py differs from upstream; any other file there fails. Needs the network, so the kit's CI runs it and
# `make check` does not.
# To bump PyYAML: put the new version and the sdist's SHA-256 (from PyPI) in requirements.txt, copy
# lib/yaml/{error,tokens,events,reader,scanner,parser}.py and LICENSE from that sdist, and run this script.
set -euo pipefail
[[ $# -eq 0 ]] || { printf 'usage: %s\n' "$0" >&2; exit 2; }
kit=$(cd "$(dirname "$0")/.." && pwd -P)
pins="$kit/scripts/vendored-pyyaml/requirements.txt"
vendored="$kit/skills/guardrails-init/template/.agent/workflow/guardrails_pyyaml"
modules="error.py tokens.py events.py reader.py scanner.py parser.py"

pin=$(sed -nE 's/^pyyaml==([0-9][0-9.]*) --hash=sha256:([0-9a-f]{64})$/\1 \2/p' "$pins")
[[ -n $pin ]] || { printf "error: no 'pyyaml==<version> --hash=sha256:<sha256>' line in %s\n" "$pins" >&2; exit 1; }
read -r version sha256 <<<"$pin"
url="https://files.pythonhosted.org/packages/source/p/pyyaml/pyyaml-$version.tar.gz"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# curl retries the same download with growing pauses and says so on each attempt.
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --retry 4 --retry-all-errors \
  --output "$work/sdist.tar.gz" "$url"
got=$(shasum -a 256 "$work/sdist.tar.gz" | cut -d' ' -f1)
[[ $got == "$sha256" ]] || { printf 'error: checksum mismatch for %s: want sha256 %s, got %s\n' "$url" "$sha256" "$got" >&2; exit 1; }
mkdir "$work/sdist"
tar -xzf "$work/sdist.tar.gz" -C "$work/sdist"
upstream="$work/sdist/pyyaml-$version"

status=0
for file in $modules; do
  cmp -s "$upstream/lib/yaml/$file" "$vendored/$file" || { printf 'differs from PyYAML %s: %s\n' "$version" "$file"; status=1; }
done
cmp -s "$upstream/LICENSE" "$vendored/LICENSE" || { printf 'differs from PyYAML %s: LICENSE\n' "$version"; status=1; }
for path in "$vendored"/* "$vendored"/.[!.]*; do
  [[ -e $path ]] || continue
  case " $modules LICENSE __init__.py " in
    *" ${path##*/} "*) ;;
    *) printf 'not part of the vendored parser: %s\n' "${path##*/}"; status=1 ;;
  esac
done
[[ $status -eq 0 ]] && printf 'guardrails_pyyaml matches PyYAML %s (sdist sha256 %s)\n' "$version" "$sha256"
exit "$status"
