#!/bin/bash
# Deletes every release "v<version>" that neither channel's manifest names.
# Servers download from releases.bhpanel.net, which keeps its own copies, so
# GitHub only needs the version(s) a channel points at - the one the mirror
# may still have to fetch. "channel-*" and "incoming-*" are never touched.
#
#   ci/prune.sh       needs GH_TOKEN
set -euo pipefail
REPO="${GITHUB_REPOSITORY:-wpexpertinbd/bhpanel-releases}"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

keep=""
for ch in beta stable; do
  if gh release download "channel-$ch" --repo "$REPO" --dir "$W/$ch" --pattern manifest.json >/dev/null 2>&1; then
    v=$(jq -r '.version // empty' "$W/$ch/manifest.json")
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "channel-$ch names no version - pruning nothing"; exit 0; }
    keep="$keep v$v"
  fi
done
[ -n "$keep" ] || { echo "no channel names a version - pruning nothing"; exit 0; }
echo "keeping:$keep"

gh release list --repo "$REPO" --limit 200 --json tagName -q '.[].tagName' | while read -r tag; do
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
  case " $keep " in *" $tag "*) continue ;; esac
  echo "deleting $tag"
  gh release delete "$tag" --repo "$REPO" --yes --cleanup-tag
done
