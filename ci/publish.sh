#!/bin/bash
# Signs BHPanel <version> (prerelease "incoming-<version>", already checked by
# publish.yml) and publishes it to the beta channel.
#
#   ci/publish.sh <version>     needs BHP_RELEASE_KEY and GH_TOKEN
#
# The manifest names each file with its sha256 and size - no URLs: a server
# fetches the files from the mirror it took the manifest from.
set -euo pipefail
V="${1:?version}"
[[ "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "not a version: $V"; exit 1; }
: "${BHP_RELEASE_KEY:?}" "${GH_TOKEN:?}"
REPO="${GITHUB_REPOSITORY:-wpexpertinbd/bhpanel-releases}"
# The oldest panel this release's installer upgrades from.
MIN_FROM=0.2.20
# The public half of the release key - built into bhpaneld
# (panelReleasePublicKeys) and the mirror (server/release-sync.sh).
RELEASE_PUB=AikuERko5esVXrO+/Zp6juc4CXu73p5tcmwpRFfB89A=
HERE="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

(cd "$HERE/tool" && go build -o "$W/bhp-release" .)
mkdir "$W/in"
gh release download "incoming-$V" --repo "$REPO" --dir "$W/in"
cd "$W/in"

files='{}'
for a in x86_64 aarch64; do
  f="bhpanel-$V-linux-$a.tar.gz"
  sha256sum -c "$f.sha256"
  sum=$(sha256sum "$f" | cut -d' ' -f1)
  size=$(stat -c %s "$f")
  files=$(jq -c --arg a "$a" --arg n "$f" --arg s "$sum" --argjson z "$size" '. + {($a): {name: $n, sha256: $s, size: $z}}' <<<"$files")
done

# The version's own release: the files, once.
if ! gh release view "v$V" --repo "$REPO" >/dev/null 2>&1; then
  gh release create "v$V" --repo "$REPO" --title "BHPanel $V" \
    --notes "Signed BHPanel release $V. Servers install it through their panel's updater; the checksums are in the channel manifests."
fi
gh release upload "v$V" --repo "$REPO" --clobber bhpanel-"$V"-linux-*.tar.gz bhpanel-"$V"-linux-*.tar.gz.sha256

jq -n --arg v "$V" --arg min "$MIN_FROM" --arg p "$(date -u +%FT%TZ)" --argjson f "$files" \
  '{schema: 1, channel: "beta", version: $v, published: $p, min_from: $min, files: $f}' > "$W/manifest.json"
BHP_RELEASE_KEY="$BHP_RELEASE_KEY" "$W/bhp-release" sign "$W/manifest.json" "$W/manifest.json.sig"
# Checked the way a server checks it: against the key servers have built in
# (a secret replaced by mistake would sign releases no server accepts).
"$W/bhp-release" verify "$W/manifest.json" "$W/manifest.json.sig" "$RELEASE_PUB" \
  || { echo "the secret BHP_RELEASE_KEY is not the key servers trust ($RELEASE_PUB)"; exit 1; }

if ! gh release view channel-beta --repo "$REPO" >/dev/null 2>&1; then
  gh release create channel-beta --repo "$REPO" --prerelease --title "Channel: beta" \
    --notes "The beta channel's signed manifest. The newest is the one here."
fi
gh release upload channel-beta --repo "$REPO" --clobber "$W/manifest.json" "$W/manifest.json.sig"
cat "$W/manifest.json"

gh release delete "incoming-$V" --repo "$REPO" --yes --cleanup-tag
echo "published $V to beta"
