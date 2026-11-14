#!/bin/bash
# Deletes the releases "v<version>" nobody can still need: older than
# KEEP_DAYS and named by neither channel's manifest. Servers download from
# releases.bhpanel.net, which keeps its own copies, so GitHub needs the
# version(s) a channel points at - the one the mirror may still have to fetch -
# and the recent betas: a stable release is a beta that ran a week cleanly,
# promoted from its own release (promote.sh) when beta has long moved on.
# "channel-*" and "incoming-*" are never touched.
#
#   ci/prune.sh       needs GH_TOKEN
set -euo pipefail
REPO="${GITHUB_REPOSITORY:-wpexpertinbd/bhpanel-releases}"
KEEP_DAYS="${KEEP_DAYS:-21}"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

keep=""
for ch in beta stable; do
  # Only "this channel does not exist yet" may leave it out; a channel that
  # exists but could not be read prunes nothing - it may name an old release
  # (Codex).
  if ! out=$(gh release view "channel-$ch" --repo "$REPO" --json tagName 2>&1); then
    grep -q 'release not found' <<<"$out" || { echo "channel-$ch could not be looked up - pruning nothing: $out"; exit 0; }
    continue
  fi
  gh release download "channel-$ch" --repo "$REPO" --dir "$W/$ch" --pattern manifest.json >/dev/null 2>&1 \
    || { echo "channel-$ch's manifest could not be read - pruning nothing"; exit 0; }
  v=$(jq -r '.version // empty' "$W/$ch/manifest.json")
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "channel-$ch names no version - pruning nothing"; exit 0; }
  keep="$keep v$v"
done
[ -n "$keep" ] || { echo "no channel names a version - pruning nothing"; exit 0; }
cutoff=$(date -u -d "-$KEEP_DAYS days" +%FT%TZ)
echo "keeping:$keep and every release since $cutoff"

gh release list --repo "$REPO" --limit 1000 --json tagName,publishedAt \
  -q '.[] | "\(.tagName) \(.publishedAt)"' > "$W/list"
while read -r tag at; do
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
  case " $keep " in *" $tag "*) continue ;; esac
  # ISO 8601 in UTC compares as text; an unreadable date is kept, not deleted.
  [[ "$at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] || { echo "keeping $tag: no publish date ($at)"; continue; }
  [[ "$at" < "$cutoff" ]] || continue
  echo "deleting $tag (published $at)"
  gh release delete "$tag" --repo "$REPO" --yes --cleanup-tag </dev/null
done < "$W/list"
