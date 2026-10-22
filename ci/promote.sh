#!/bin/bash
# Makes the beta channel's version <version> the stable one: the beta manifest,
# signature-checked, re-signed with channel "stable".
#
#   ci/promote.sh <version>     needs BHP_RELEASE_KEY and GH_TOKEN
set -euo pipefail
V="${1:?version}"
[[ "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "not a version: $V"; exit 1; }
: "${BHP_RELEASE_KEY:?}" "${GH_TOKEN:?}"
REPO="${GITHUB_REPOSITORY:-wpexpertinbd/bhpanel-releases}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

(cd "$HERE/tool" && go build -o "$W/bhp-release" .)
# The key servers have built in (bhpaneld panelReleasePublicKeys).
pub=AikuERko5esVXrO+/Zp6juc4CXu73p5tcmwpRFfB89A=
gh release download channel-beta --repo "$REPO" --dir "$W/beta" --pattern 'manifest.json*'
"$W/bhp-release" verify "$W/beta/manifest.json" "$W/beta/manifest.json.sig" "$pub"
got=$(jq -r .version "$W/beta/manifest.json")
[ "$got" = "$V" ] || { echo "beta has $got, not $V - only the version in beta is promoted"; exit 1; }

jq --arg p "$(date -u +%FT%TZ)" '.channel = "stable" | .promoted = $p' "$W/beta/manifest.json" > "$W/manifest.json"
BHP_RELEASE_KEY="$BHP_RELEASE_KEY" "$W/bhp-release" sign "$W/manifest.json" "$W/manifest.json.sig" >/dev/null
"$W/bhp-release" verify "$W/manifest.json" "$W/manifest.json.sig" "$pub"
if ! gh release view channel-stable --repo "$REPO" >/dev/null 2>&1; then
  gh release create channel-stable --repo "$REPO" --title "Channel: stable" \
    --notes "The stable channel's signed manifest. The newest is the one here."
fi
gh release upload channel-stable --repo "$REPO" --clobber "$W/manifest.json" "$W/manifest.json.sig"
cat "$W/manifest.json"
echo "promoted $V to stable"
bash "$HERE/ci/prune.sh" || echo "pruning old releases failed - nothing else is affected"
