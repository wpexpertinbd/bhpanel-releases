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
# The one-line installer (install/install.sh) travels with the release, named
# by sha256 in the signed manifest: the mirror serves it only when it matches.
cp "$HERE/install/install.sh" install.sh
inst=$(jq -n --arg s "$(sha256sum install.sh | cut -d' ' -f1)" --argjson z "$(stat -c %s install.sh)" '{sha256: $s, size: $z}')
gh release upload "v$V" --repo "$REPO" --clobber bhpanel-"$V"-linux-*.tar.gz bhpanel-"$V"-linux-*.tar.gz.sha256 install.sh

# security_fix: the newest release so far that fixed a security problem -
# this one when it came with security.txt, else what the beta channel already
# said (checked against the release key first). A panel older than it shows
# the update as urgent; panels before 0.2.80 ignore the field.
fix=""
if [ -f security.txt ]; then
  [ "$(cat security.txt)" = yes ] || { echo "security.txt must say yes"; exit 1; }
  fix="$V"
elif ! prev=$(gh release view channel-beta --repo "$REPO" --json tagName 2>&1); then
  # Only "there is no beta channel yet" means there is no earlier fix; any
  # other failure would sign this release without it (Codex).
  grep -q 'release not found' <<<"$prev" || { echo "the beta channel could not be looked up: $prev"; exit 1; }
else
  gh release download channel-beta --repo "$REPO" --dir "$W/prev" --pattern 'manifest.json*' \
    || { echo "the beta channel's current manifest could not be downloaded"; exit 1; }
  "$W/bhp-release" verify "$W/prev/manifest.json" "$W/prev/manifest.json.sig" "$RELEASE_PUB" \
    || { echo "the beta channel's current manifest does not verify"; exit 1; }
  fix=$(jq -r '.security_fix // ""' "$W/prev/manifest.json")
  [ -z "$fix" ] || [[ "$fix" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "the beta manifest's security_fix is not a version: $fix"; exit 1; }
fi
echo "security_fix: ${fix:-none}"

jq -n --arg v "$V" --arg min "$MIN_FROM" --arg p "$(date -u +%FT%TZ)" --argjson f "$files" --argjson i "$inst" --arg fix "$fix" \
  '{schema: 1, channel: "beta", version: $v, published: $p, min_from: $min, files: $f, install_script: $i}
   + (if $fix == "" then {} else {security_fix: $fix} end)' > "$W/manifest.json"
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
# Only the versions a channel names stay on GitHub (servers use the mirror).
bash "$HERE/ci/prune.sh" || echo "pruning old releases failed - nothing else is affected"
