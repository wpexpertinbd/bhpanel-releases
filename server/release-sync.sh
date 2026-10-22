#!/bin/bash
# releases.bhpanel.net: mirror the signed BHPanel release channels published by
# github.com/wpexpertinbd/bhpanel-releases. Runs as root from a systemd timer
# on the web server. Only downloads.
#
# ⚠ Everything it writes is root's, never the site account's (2026-10-22): the
# account runs the bhpanel.net website, and a hole in it must not reach what
# servers install. The site's own folder is IMMUTABLE (chattr +i) - the account
# cannot swap it or a subfolder for another or a link - and its subfolders are
# root's. This script never unlocks it: the account owns its parent and could
# swap the folder in that moment (Codex). Its top level (beta/, stable/,
# files/, install.sh) was made by hand; a missing one is reported, not made.
#
# For each channel (beta, stable): manifest.json must carry a valid ed25519
# signature by the PINNED key below, name only files of the expected form, and
# never go back to an older version than the one live; every file it names must
# match its sha256 and size. Files go live first, the manifest after them, so a
# server never reads a manifest naming a missing file. Anything else is refused,
# the site keeps what it had, and ALERT is told - once per refused manifest.
set -euo pipefail
PUB=AikuERko5esVXrO+/Zp6juc4CXu73p5tcmwpRFfB89A=   # ~/BHPanel-keys/release-signing/public.txt (base64, 32 bytes)
GH="https://github.com/wpexpertinbd/bhpanel-releases/releases/download"
SITE=/home/bhpmain/releases.bhpanel.net
STATE=/root/bhpanel-releases
ALERT=info@biswashost.com
KEEP_VERSIONS=3
install -d -m 700 "$STATE"
exec 9>"$STATE/lock"; flock -n 9 || exit 0

notify() { # subject, body (stdin)
  { printf 'To: %s\nFrom: root@%s\nSubject: [releases.bhpanel.net] %s\nContent-Type: text/plain; charset=UTF-8\n\n' \
      "$ALERT" "$(hostname -f)" "$1"; cat; } | /usr/sbin/sendmail -t -oi || echo "the alert could not be sent"
}
W=$(mktemp -d "$STATE/work.XXXXXX")
trap 'rm -rf "$W"' EXIT

# The pinned key as a PEM OpenSSL can check ed25519 with (DER prefix + key).
[[ "$PUB" =~ ^[A-Za-z0-9+/]{43}=$ ]] || { echo "no release public key is configured"; exit 1; }
{ echo "-----BEGIN PUBLIC KEY-----"
  { printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'; printf '%s' "$PUB" | base64 -d; } | base64
  echo "-----END PUBLIC KEY-----"; } > "$W/pub.pem"

[ ! -L "$SITE" ] && [ -d "$SITE" ] && [ "$(stat -c %u "$SITE")" = 0 ] || { echo "$SITE is not root's own folder"; exit 1; }
top_change() { # a change to the locked folder's top level: by hand only
  printf 'releases.bhpanel.net needs a change at the top of %s that this script does not make:\n  %s\nBy hand: chattr -i %s, make it (root-owned), chattr +i %s.\n' "$SITE" "$*" "$SITE" "$SITE" |
    notify "by-hand step needed"
  return 1
}

changed=""
sync_channel() {
  local ch="$1" d sum live v name sha size f
  d="$W/$ch"
  mkdir -p "$d"
  curl -fsSL -m 60 -o "$d/manifest.json" "$GH/channel-$ch/manifest.json" 2>/dev/null || { echo "$ch: no manifest published"; return 0; }
  curl -fsSL -m 60 -o "$d/manifest.json.sig" "$GH/channel-$ch/manifest.json.sig" || { echo "$ch: no signature"; return 0; }
  sum=$(sha256sum "$d/manifest.json" | cut -d' ' -f1)
  [ -f "$SITE/$ch/manifest.json" ] && [ "$(sha256sum "$SITE/$ch/manifest.json" | cut -d' ' -f1)" = "$sum" ] && return 0

  refuse() {
    echo "REFUSED $ch: $1"
    if [ "$(cat "$STATE/refused-$ch.txt" 2>/dev/null)" != "$sum" ]; then
      printf 'The %s channel manifest was REFUSED and NOT put live. Servers keep the previous one.\n\nReason: %s\nManifest sha256: %s\nServer: %s\nTime: %s\n\nIf you did not publish this, treat the GitHub account wpexpertinbd as compromised.\n' \
        "$ch" "$1" "$sum" "$(hostname -f)" "$(date -u '+%F %T UTC')" | notify "REFUSED $ch manifest"
      echo "$sum" > "$STATE/refused-$ch.txt"
    fi
  }

  base64 -d "$d/manifest.json.sig" > "$d/sig.bin" 2>/dev/null || { refuse "the signature is not base64"; return 0; }
  openssl pkeyutl -verify -pubin -inkey "$W/pub.pem" -rawin -in "$d/manifest.json" -sigfile "$d/sig.bin" >/dev/null 2>&1 \
    || { refuse "bad signature"; return 0; }

  v=$(jq -r '.version // empty' "$d/manifest.json")
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { refuse "not a version: $v"; return 0; }
  [ "$(jq -r '.schema' "$d/manifest.json")" = 1 ] && [ "$(jq -r '.channel' "$d/manifest.json")" = "$ch" ] \
    || { refuse "wrong schema or channel"; return 0; }
  live=$(jq -r '.version // empty' "$SITE/$ch/manifest.json" 2>/dev/null || true)
  if [ -n "$live" ] && [ "$(printf '%s\n%s\n' "$live" "$v" | sort -V | head -1)" = "$v" ] && [ "$live" != "$v" ]; then
    refuse "older than the live $live: $v"; return 0
  fi

  mkdir -p "$d/files"
  for a in x86_64 aarch64; do
    name=$(jq -r --arg a "$a" '.files[$a].name // empty' "$d/manifest.json")
    sha=$(jq -r --arg a "$a" '.files[$a].sha256 // empty' "$d/manifest.json")
    size=$(jq -r --arg a "$a" '.files[$a].size // empty' "$d/manifest.json")
    [ "$name" = "bhpanel-$v-linux-$a.tar.gz" ] || { refuse "unexpected file name for $a: $name"; return 0; }
    [[ "$sha" =~ ^[0-9a-f]{64}$ && "$size" =~ ^[0-9]+$ ]] || { refuse "bad checksum or size for $a"; return 0; }
    f="$SITE/files/$name"
    if [ -f "$f" ] && [ "$(sha256sum "$f" | cut -d' ' -f1)" = "$sha" ]; then
      continue
    fi
    curl -fsSL -m 1800 --max-filesize $((size + 1)) -o "$d/files/$name" "$GH/v$v/$name" || { echo "$ch: download of $name failed, tried again later"; return 0; }
    [ "$(stat -c %s "$d/files/$name")" = "$size" ] || { refuse "$name is not $size bytes"; return 0; }
    echo "$sha  $d/files/$name" | sha256sum -c --quiet || { refuse "$name does not match its checksum"; return 0; }
  done

  # Files first, then the manifest that names them.
  for sub in files "$ch"; do
    [ -d "$SITE/$sub" ] || { top_change "make $SITE/$sub (root, 0755)"; return 0; }
  done
  for f in "$d"/files/*; do
    [ -e "$f" ] || continue
    install -o root -g root -m 644 "$f" "$SITE/files/.$(basename "$f").new"
    mv -f "$SITE/files/.$(basename "$f").new" "$SITE/files/$(basename "$f")"
  done
  for f in manifest.json manifest.json.sig; do
    install -o root -g root -m 644 "$d/$f" "$SITE/$ch/.$f.new"
  done
  # The signature lands last but both are in place within the same instant;
  # a server that reads the new manifest with the old signature refuses it and
  # tries again at its next check.
  mv -f "$SITE/$ch/.manifest.json.sig.new" "$SITE/$ch/manifest.json.sig"
  mv -f "$SITE/$ch/.manifest.json.new" "$SITE/$ch/manifest.json"
  echo "live: $ch $v"
  changed="$changed $ch=$v"
}

sync_channel beta
sync_channel stable

# The one-line installer (releases.bhpanel.net/install.sh): the copy the
# stable manifest names, else beta's - fetched from that version's release and
# put live only when it matches the sha256 and size in the SIGNED manifest.
for ch in stable beta; do
  m="$SITE/$ch/manifest.json"
  [ -f "$m" ] || continue
  v=$(jq -r '.version // empty' "$m")
  isha=$(jq -r '.install_script.sha256 // empty' "$m")
  isize=$(jq -r '.install_script.size // empty' "$m")
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$isha" =~ ^[0-9a-f]{64}$ && "$isize" =~ ^[0-9]+$ ]] || continue
  if [ -f "$SITE/install.sh" ] && [ "$(sha256sum "$SITE/install.sh" | cut -d' ' -f1)" = "$isha" ]; then
    break
  fi
  if curl -fsSL -m 60 --max-filesize $((isize + 1)) -o "$W/install.sh" "$GH/v$v/install.sh" &&
    [ "$(stat -c %s "$W/install.sh")" = "$isize" ] &&
    [ "$(sha256sum "$W/install.sh" | cut -d' ' -f1)" = "$isha" ]; then
    # Rewritten in place: the locked folder takes no new name, and the file
    # cannot be swapped there. A download caught half way runs nothing - the
    # script's main is called on its last line.
    if [ -f "$SITE/install.sh" ] && [ ! -L "$SITE/install.sh" ]; then
      cat "$W/install.sh" >"$SITE/install.sh"
      echo "live: install.sh from $ch $v"
      changed="$changed install.sh=$v"
    else
      top_change "make $SITE/install.sh (root, 0644)" || true
    fi
  else
    echo "install.sh of $ch $v could not be fetched or does not match its signed sha256 - the live one is kept"
  fi
  break
done

# Only the newest KEEP_VERSIONS versions' files stay, and never one a channel names.
keep=$(for ch in beta stable; do jq -r '.files[].name' "$SITE/$ch/manifest.json" 2>/dev/null || true; done | sort -u)
mapfile -t versions < <(find "$SITE/files" -maxdepth 1 -type f -name 'bhpanel-*-linux-*.tar.gz' -printf '%f\n' 2>/dev/null \
  | sed -E 's/^bhpanel-([0-9]+\.[0-9]+\.[0-9]+)-linux-.*/\1/' | sort -uV)
n=${#versions[@]}
if [ "$n" -gt "$KEEP_VERSIONS" ]; then
  for v in "${versions[@]:0:$((n - KEEP_VERSIONS))}"; do
    for a in x86_64 aarch64; do
      f="bhpanel-$v-linux-$a.tar.gz"
      grep -qxF "$f" <<<"$keep" || rm -f "$SITE/files/$f"
    done
  done
fi

if [ -n "$changed" ]; then
  printf 'A signed BHPanel release is LIVE on releases.bhpanel.net:%s\n\nServer: %s\nTime: %s\n\nIf you did not approve a publish at github.com/wpexpertinbd/bhpanel-releases/actions,\ntreat the GitHub account as compromised.\n' \
    "$changed" "$(hostname -f)" "$(date -u '+%F %T UTC')" | notify "release live:$changed"
fi
