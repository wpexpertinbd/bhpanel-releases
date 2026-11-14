#!/bin/bash
# Makes <version> the stable channel's release: the signed manifest its beta
# servers got (kept in its own release by publish.sh), signature-checked, then
# re-signed with channel "stable".
#
#   ci/promote.sh <version> [security]     needs BHP_RELEASE_KEY and GH_TOKEN
#
# The rule (his 1/a, 2026-11-10): stable is a beta that ran at least
# MIN_BETA_DAYS days, plus security fixes - "security" skips the wait, for a
# release that fixes a security problem. Never a version older than, or the
# same as, the one stable has: a server is never told to go back.
set -euo pipefail
V="${1:?version}"
MODE="${2:-}"
[[ "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "not a version: $V"; exit 1; }
[ -z "$MODE" ] || [ "$MODE" = security ] || { echo "the second argument is 'security' or nothing"; exit 1; }
: "${BHP_RELEASE_KEY:?}" "${GH_TOKEN:?}"
REPO="${GITHUB_REPOSITORY:-wpexpertinbd/bhpanel-releases}"
MIN_BETA_DAYS="${MIN_BETA_DAYS:-7}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

(cd "$HERE/tool" && go build -o "$W/bhp-release" .)
# The key servers have built in (bhpaneld panelReleasePublicKeys).
pub=AikuERko5esVXrO+/Zp6juc4CXu73p5tcmwpRFfB89A=

# The version's own beta manifest; a release published before publish.sh kept
# one can only be promoted while it is still the beta channel's.
mkdir "$W/beta"
if gh release download "v$V" --repo "$REPO" --dir "$W/beta" --pattern 'manifest-beta.json*' 2>/dev/null; then
  mv "$W/beta/manifest-beta.json" "$W/beta/manifest.json"
  mv "$W/beta/manifest-beta.json.sig" "$W/beta/manifest.json.sig"
else
  gh release download channel-beta --repo "$REPO" --dir "$W/beta" --pattern 'manifest.json*' \
    || { echo "v$V has no beta manifest and the beta channel's could not be read"; exit 1; }
fi
"$W/bhp-release" verify "$W/beta/manifest.json" "$W/beta/manifest.json.sig" "$pub"
got=$(jq -r .version "$W/beta/manifest.json")
[ "$got" = "$V" ] || { echo "the beta manifest found is for $got, not $V - v$V was never published to beta, or its release is gone"; exit 1; }
[ "$(jq -r .channel "$W/beta/manifest.json")" = beta ] || { echo "that manifest is not a beta one"; exit 1; }

newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }

# A week IN beta, unless it is a security fix: from its publish until the next
# newer release replaced it (or now) - a version beta moved past the next day
# never ran a week, however long ago it was signed (Codex).
pubd=$(jq -r '.published // empty' "$W/beta/manifest.json")
[[ "$pubd" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] || { echo "the beta manifest has no publish date"; exit 1; }
start=$(date -u -d "$pubd" +%s)
end=$(date -u +%s)
gh release list --repo "$REPO" --limit 1000 --json tagName,publishedAt -q '.[] | "\(.tagName) \(.publishedAt)"' > "$W/list" \
  || { echo "the releases could not be listed"; exit 1; }
while read -r tag at; do
  [[ "$tag" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]] || continue
  newer "${BASH_REMATCH[1]}" "$V" || continue
  t=$(date -u -d "$at" +%s 2>/dev/null) || continue
  [ "$t" -gt "$start" ] && [ "$t" -lt "$end" ] && end=$t
done < "$W/list"
[ "$end" -ge "$start" ] || { echo "the beta manifest's publish date $pubd is in the future"; exit 1; }
age=$(( (end - start) / 86400 ))
if [ "$MODE" != security ] && [ "$age" -lt "$MIN_BETA_DAYS" ]; then
  echo "$V ran $age day(s) in beta; stable takes a beta that ran $MIN_BETA_DAYS days (or a security fix: 'security')"
  exit 1
fi

# Its files must still be there to fetch: the mirror takes them from v<version>.
gh release view "v$V" --repo "$REPO" --json assets -q '.assets[].name' > "$W/assets" \
  || { echo "the release v$V is gone - its files cannot be fetched"; exit 1; }
for f in $(jq -r '.files[].name' "$W/beta/manifest.json"); do
  grep -qxF "$f" "$W/assets" || { echo "v$V no longer has $f - stable would name a file nobody can fetch"; exit 1; }
done

# Never back, never the same: stable only moves forward. A stable channel that
# exists but cannot be read stops here (Codex: read as "none" it let an older
# version through).
if ! out=$(gh release view channel-stable --repo "$REPO" --json tagName 2>&1); then
  grep -q 'release not found' <<<"$out" || { echo "channel-stable could not be looked up: $out"; exit 1; }
else
  gh release download channel-stable --repo "$REPO" --dir "$W/stable" --pattern 'manifest.json*' \
    || { echo "the current stable manifest could not be read"; exit 1; }
  "$W/bhp-release" verify "$W/stable/manifest.json" "$W/stable/manifest.json.sig" "$pub" \
    || { echo "the current stable manifest does not verify - fix that first"; exit 1; }
  cur=$(jq -r .version "$W/stable/manifest.json")
  newer "$V" "$cur" || { echo "stable already has $cur; $V is not newer"; exit 1; }
fi

jq --arg p "$(date -u +%FT%TZ)" '.channel = "stable" | .promoted = $p' "$W/beta/manifest.json" > "$W/manifest.json"
BHP_RELEASE_KEY="$BHP_RELEASE_KEY" "$W/bhp-release" sign "$W/manifest.json" "$W/manifest.json.sig" >/dev/null
"$W/bhp-release" verify "$W/manifest.json" "$W/manifest.json.sig" "$pub"
if ! gh release view channel-stable --repo "$REPO" >/dev/null 2>&1; then
  gh release create channel-stable --repo "$REPO" --title "Channel: stable" \
    --notes "The stable channel's signed manifest. The newest is the one here."
fi
gh release upload channel-stable --repo "$REPO" --clobber "$W/manifest.json" "$W/manifest.json.sig"
cat "$W/manifest.json"
echo "promoted $V to stable (ran $age day(s) in beta${MODE:+, security fix})"
bash "$HERE/ci/prune.sh" || echo "pruning old releases failed - nothing else is affected"
