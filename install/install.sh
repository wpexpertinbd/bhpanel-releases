#!/bin/bash
# BHPanel - install on a fresh AlmaLinux 9 server, in one line:
#
#   curl -fsSL https://releases.bhpanel.net/install.sh | bash
#   curl -fsSL https://releases.bhpanel.net/install.sh | bash -s -- --light
#   curl -fsSL https://releases.bhpanel.net/install.sh | bash -s -- --beta --full --license <key>
#
# Every option except --beta goes to the panel's installer unchanged (--light,
# --full, --dns-only, --stack=ols, -y, --admin-user <name>, --license <key>; BHP_LICENSE
# in the environment keeps the key out of the process list).
#
# Nothing it downloads runs before it is proven to be a release the BHPanel
# release key signed: the channel manifest's ed25519 signature is checked
# against the key below, the tarball against the sha256 and size the signed
# manifest names, and every entry of the tarball is checked before unpacking.
# This script itself is named by sha256 in the signed manifest, and the
# mirror publishes it only when it matches.
# Everything is inside main, called on the very last line: a download cut off
# half way ("curl | bash") defines nothing and runs nothing.
main() {
set -euo pipefail
  umask 077

  PUB="AikuERko5esVXrO+/Zp6juc4CXu73p5tcmwpRFfB89A="
  BASE="https://releases.bhpanel.net"
  WORK=/root/bhpanel-install

  die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
  say() { printf '== %s\n' "$*"; }

  channel=stable
  args=()
  for a in "$@"; do
    case "$a" in
      --beta) channel=beta ;;
      --stable) channel=stable ;;
      *) args+=("$a") ;;
    esac
  done

  [ "$(id -u)" = 0 ] || die "run it as root (sudo -i first)"
  # shellcheck disable=SC1091
  . /etc/os-release 2>/dev/null || true
  case "${ID:-}:${VERSION_ID%%.*}" in
    almalinux:9 | rocky:9 | rhel:9) ;;
    *) die "BHPanel installs on AlmaLinux 9 (this is ${PRETTY_NAME:-unknown})" ;;
  esac
  arch="$(uname -m)"
  case "$arch" in x86_64 | aarch64) ;; *) die "no BHPanel build for this processor ($arch)" ;; esac
  for c in curl openssl tar sha256sum python3 base64; do
    command -v "$c" >/dev/null || die "$c is missing (dnf install -y $c)"
  done

  # The installer asks which profile to install. Through "curl | bash" its own
  # input is this pipe, so it gets the terminal - or, with none, must be told.
  tty_ok=0
  if { : </dev/tty; } 2>/dev/null; then
    tty_ok=1
  elif ! printf '%s\n' "${args[@]+"${args[@]}"}" | grep -qxE -- '--light|--full|--dns-only|-y'; then
    die "no terminal to ask on: add --light, --full, --dns-only or -y (curl ... | bash -s -- --light)"
  fi

  install -d -m 700 "$WORK"
  W="$(mktemp -d "$WORK/tmp.XXXXXX")"
  trap 'rm -rf "$W"' EXIT

  say "1. the $channel channel's signed release list"
  if ! curl -fsSL -m 60 -o "$W/manifest.json" "$BASE/$channel/manifest.json"; then
    [ "$channel" = stable ] && die "no stable release is published yet - add --beta for the newest one"
    die "the $channel release list could not be downloaded"
  fi
  curl -fsSL -m 60 -o "$W/manifest.json.sig" "$BASE/$channel/manifest.json.sig" || die "the signature could not be downloaded"
  { echo "-----BEGIN PUBLIC KEY-----"
    { printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'; printf '%s' "$PUB" | base64 -d; } | base64
    echo "-----END PUBLIC KEY-----"; } >"$W/pub.pem"
  sig_ok() {
    base64 -d <"$W/manifest.json.sig" >"$W/sig.bin" 2>/dev/null &&
      openssl pkeyutl -verify -pubin -inkey "$W/pub.pem" -rawin -in "$W/manifest.json" -sigfile "$W/sig.bin" >/dev/null 2>&1
  }
  if ! sig_ok; then
    # The mirror puts a new list and its signature live one after the other;
    # fetched in between, the two do not belong together. Once more, both.
    sleep 5
    if ! { curl -fsSL -m 60 -o "$W/manifest.json" "$BASE/$channel/manifest.json" &&
      curl -fsSL -m 60 -o "$W/manifest.json.sig" "$BASE/$channel/manifest.json.sig" && sig_ok; }; then
      die "the release list's SIGNATURE DOES NOT CHECK OUT - nothing was installed. Tell support@biswashost.com."
    fi
  fi
  echo "   signature checked against the BHPanel release key"

  # Only now is the list read - and strictly.
  read -r ver name sha size < <(python3 -I - "$W/manifest.json" "$channel" "$arch" <<'PY'
import json, re, sys
m = json.load(open(sys.argv[1]))
ch, arch = sys.argv[2], sys.argv[3]
v = m.get("version", "")
assert m.get("schema") == 1 and m.get("channel") == ch, "wrong schema or channel"
assert re.fullmatch(r"(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})", v), "bad version"
f = m["files"][arch]
assert f["name"] == "bhpanel-%s-linux-%s.tar.gz" % (v, arch), "unexpected file name"
assert re.fullmatch(r"[0-9a-f]{64}", f["sha256"]), "bad sha256"
assert isinstance(f["size"], int) and 0 < f["size"] <= 2 << 30, "bad size"
print(v, f["name"], f["sha256"], f["size"])
PY
  ) || die "the signed release list is not in the expected form"
  echo "   BHPanel $ver ($channel) for $arch"

  say "2. downloading $name ($((size >> 20)) MB)"
  curl -fsSL -m 3600 --max-filesize $((size + 1)) -o "$W/$name" "$BASE/files/$name" || die "the download failed - try again"
  [ "$(stat -c %s "$W/$name")" = "$size" ] || die "$name is not the $size bytes the signed list names"
  echo "$sha  $W/$name" | sha256sum -c --quiet || die "$name does not match the signed sha256 - nothing was installed"
  echo "   matches the signed sha256"

  say "3. unpacking"
  top="bhpanel-$ver-linux-$arch"
  # Every entry: a plain file or folder, inside the release's own top folder -
  # read by Python's tar parser, not from tar's listing text.
  python3 -I - "$W/$name" "$top" <<'PY' || die "the release holds something besides plain files under $top/ - not unpacked"
import sys, tarfile
top = sys.argv[2]
with tarfile.open(sys.argv[1], "r:gz") as t:
    for n, m in enumerate(t):
        if n >= 50000:
            sys.exit("more than 50000 entries")
        if not (m.isreg() or m.isdir()):
            sys.exit("not a plain file or folder: %r" % m.name)
        parts = m.name.rstrip("/").split("/")
        if (m.name.startswith("/") or "\\" in m.name or "\0" in m.name or parts[0] != top
                or any(p in ("", ".", "..") for p in parts)):
            sys.exit("outside %s/: %r" % (top, m.name))
PY
  dest="$WORK/$top"
  rm -rf -- "$dest"
  tar -xzf "$W/$name" -C "$WORK" --no-same-owner --no-same-permissions
  [ -f "$dest/installer/bhpanel-install.sh" ] && [ ! -L "$dest/installer" ] || die "the release has no installer"
  (cd "$dest/bin" && sha256sum -c --strict --quiet SHA256SUMS) || die "the release's binaries do not match its SHA256SUMS"

  say "4. the installer ($dest)"
  cd "$dest"
  local rc=0
  if [ "$tty_ok" = 1 ]; then
    bash installer/bhpanel-install.sh all "${args[@]+"${args[@]}"}" </dev/tty || rc=$?
  else
    bash installer/bhpanel-install.sh all "${args[@]+"${args[@]}"}" </dev/null || rc=$?
  fi
  if [ "$rc" != 0 ]; then
    # The installer's own guidance names installer/bhpanel-install.sh; through
    # this command nobody knows where that folder is. The installer is safe to
    # run again, so the same line continues where it stopped.
    printf '\nThe release is unpacked in %s\n' "$dest"
    printf 'To continue (after a reboot, if the installer asked for one), run the same command again:\n'
    local shown=() prev=""
    for a in "$@"; do
      if [ "$prev" = --license ]; then shown+=("YOUR-KEY"); else shown+=("$a"); fi
      prev="$a"
    done
    if [ "$#" -gt 0 ]; then
      printf '    curl -fsSL %s/install.sh | bash -s --%s\n' "$BASE" "$(printf ' %q' "${shown[@]}")"
    else
      printf '    curl -fsSL %s/install.sh | bash\n' "$BASE"
    fi
  fi
  return "$rc"
}

main "$@"
