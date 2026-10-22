#!/bin/bash
# Makes BHPanel's RELEASE signing key ON THIS MAC, once (ed25519).
#
#   - the private key goes straight into GitHub: secret BHP_RELEASE_KEY of the
#     protected environment "sign" of wpexpertinbd/bhpanel-releases (used only
#     after the owner approves), piped - never written to disk in the clear
#   - an ENCRYPTED backup goes to ~/BHPanel-keys/release-signing/, with a
#     passphrase you choose (gpg asks); it is test-decrypted before the end
#   - only the PUBLIC key is printed and saved - it is built into bhpaneld
#
# Whoever holds this key can publish panel releases every BHPanel server
# installs as root. Keep the backup and its passphrase apart.
set -euo pipefail
REPO=wpexpertinbd/bhpanel-releases
ENV=sign
OUT="$HOME/BHPanel-keys/release-signing"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }
command -v gpg >/dev/null || die "gpg is not installed (brew install gnupg)"
command -v gh  >/dev/null || die "gh is not installed (brew install gh)"
command -v go  >/dev/null || die "go is not installed"
gh auth status >/dev/null 2>&1 || die "gh is not logged in (gh auth login)"
[ -e "$OUT/public.txt" ] && die "a key already exists in $OUT - this never makes a second one"
gh api "repos/$REPO/environments/$ENV" --jq '.protection_rules[].type' 2>/dev/null | grep -q required_reviewers \
  || die "the '$ENV' environment of $REPO has no approval rule - not putting a key there"

umask 077
mkdir -p "$OUT"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

echo "== 1. building the signing tool"
(cd "$HERE/tool" && go build -o "$T/bhp-release" .)

echo "== 2. generating the key"
read -r seed pub < <("$T/bhp-release" keygen)
[ ${#seed} = 44 ] && [ ${#pub} = 44 ] || die "the key did not come out right"
# gpg asks for the passphrase on this terminal (it cannot when its input is a
# pipe: "Inappropriate ioctl for device"), so the key goes to it as a file in
# the private temporary folder, removed on exit.
GPG_TTY="$(tty)" || die "run this in a terminal - gpg asks for a passphrase"
export GPG_TTY
printf '%s' "$seed" > "$T/seed"

# The backup first: the key reaches GitHub only once a copy is proven to
# decrypt, so a failure here leaves nothing anywhere.
echo "== 3. encrypted backup (choose a passphrase - gpg asks twice)"
rm -f "$OUT/private-backup.asc.gpg"
gpg --symmetric --armor --cipher-algo AES256 --output "$OUT/private-backup.asc.gpg" "$T/seed" \
  || die "gpg could not make the backup - nothing was sent to GitHub; run this again"
echo "   test-decrypting the backup (gpg may ask for the passphrase again)"
back=$(gpg --quiet --decrypt "$OUT/private-backup.asc.gpg") || die "the backup did not decrypt - nothing was sent to GitHub"
[ "$back" = "$seed" ] || die "the backup does not decrypt to the key - nothing was sent to GitHub"
unset back

echo "== 4. private key -> GitHub ($REPO, environment '$ENV')"
gh secret set BHP_RELEASE_KEY --repo "$REPO" --env "$ENV" < "$T/seed"
unset seed
rm -f "$T/seed"

echo "== 5. public key"
printf '%s\n' "$pub" > "$OUT/public.txt"
cat > "$OUT/README.txt" <<EOF
BHPanel release signing key (ed25519), made $(date -u '+%F %T UTC').
public.txt              the public key - built into bhpaneld (daemon/panel_update.go)
private-backup.asc.gpg  the private key, encrypted with your passphrase (gpg --decrypt)
The live copy is GitHub secret BHP_RELEASE_KEY, environment "sign", $REPO.
EOF
echo
echo "PUBLIC KEY: $pub"
echo "Done. Keep $OUT/private-backup.asc.gpg and its passphrase apart (e.g. USB/Drive + password manager)."
