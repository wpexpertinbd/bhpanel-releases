#!/bin/bash
# Deletes the releases "v<version>" nobody can still need. Kept (his 1/a,
# 2026-11-16 - the list had grown to a dozen in three days):
#   * the newest KEEP_LATEST versions (the latest and 3 before it);
#   * the version each channel's manifest names;
#   * the stable candidates: versions newer than stable's that RAN about
#     MIN_BETA_DAYS days in beta - no newer one for that long (promote.sh's
#     rule) - and the version after each. A stable release is promoted from
#     its own release, often long after beta moved on.
# Servers download from releases.bhpanel.net, which keeps its own copies.
# "channel-*" and "incoming-*" are never touched.
#
# ⚠ How long a version ran is read from the FULL list, before anything is
# deleted: once its successor is gone, the next one left looks like where it
# stopped, and it would seem to have run longer than it did. Every version
# newer than one kept for being recent is kept too, so promote.sh reads true
# ages for them.
#
#   ci/prune.sh       needs GH_TOKEN
set -euo pipefail
REPO="${GITHUB_REPOSITORY:-wpexpertinbd/bhpanel-releases}"
KEEP_LATEST="${KEEP_LATEST:-4}"
MIN_BETA_DAYS="${MIN_BETA_DAYS:-7}"
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

gh release list --repo "$REPO" --limit 1000 --json tagName,publishedAt \
  -q '.[] | "\(.tagName) \(.publishedAt)"' > "$W/list" \
  || { echo "the releases could not be listed - pruning nothing"; exit 0; }

# The versions, newest first, with their publish time in seconds. One whose
# date cannot be read stops the run: its place in time is unknown.
: > "$W/vers"
while read -r tag at; do
  [[ "$tag" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]] || continue
  t=$(date -u -d "$at" +%s 2>/dev/null) || { echo "no publish date for $tag ($at) - pruning nothing"; exit 0; }
  echo "${BASH_REMATCH[1]} $t" >> "$W/vers"
done < "$W/list"
sort -t' ' -k1,1Vr "$W/vers" -o "$W/vers"
mapfile -t vers < "$W/vers"
[ "${#vers[@]}" -gt "$KEEP_LATEST" ] || { echo "${#vers[@]} version(s) - nothing to prune"; exit 0; }

# The newest KEEP_LATEST.
for ((i = 0; i < KEEP_LATEST; i++)); do keep="$keep v${vers[$i]%% *}"; done

# Stable candidates: every version newer than stable's that ran at least
# MIN_BETA_DAYS-1 days before the next newer one was published (the newest:
# until now) - a day short, because promote.sh times a run from the signed
# beta manifest, minutes after the release here (Codex). Each candidate's
# successor stays too: its date is where promote.sh sees the run end, and
# with it gone the next one left would make the run look longer (Codex).
# Down to the first that clearly ran the full time; while releases come
# daily that is one or two, beside the newest four.
stable_v=""
[ -f "$W/stable/manifest.json" ] && stable_v=$(jq -r '.version' "$W/stable/manifest.json")
newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }
now=$(date -u +%s)
end=$now
succ=""
for line in "${vers[@]}"; do
  v=${line%% *} t=${line##* }
  [ -n "$stable_v" ] && ! newer "$v" "$stable_v" && break
  if [ $(( (end - t) / 86400 )) -ge $(( MIN_BETA_DAYS - 1 )) ]; then
    keep="$keep v$v"
    [ -n "$succ" ] && keep="$keep v$succ"
    echo "stable candidate: $v (ran $(( (end - t) / 86400 )) days)"
    # One that ran a day past the rule qualifies whatever the minutes: no
    # older one is needed (stable never goes back past it).
    [ $(( (end - t) / 86400 )) -ge $(( MIN_BETA_DAYS + 1 )) ] && break
  fi
  # A version published before a newer one's time ends there; equal or odd
  # orders (a re-published older one) never extend another's run.
  [ "$t" -lt "$end" ] && end=$t
  succ=$v
done
echo "keeping:$keep"

for line in "${vers[@]}"; do
  tag="v${line%% *}"
  case " $keep " in *" $tag "*) continue ;; esac
  echo "deleting $tag"
  gh release delete "$tag" --repo "$REPO" --yes --cleanup-tag </dev/null
done
