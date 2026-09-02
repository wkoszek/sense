#!/bin/bash
# Cut a release: bump the version, build a universal binary, sign it with the
# Developer ID, notarize it, publish the tarball to GitHub, and print the
# Homebrew formula stanza that points at it.
#
#   make release BUMP=patch|minor|major
#   make release VERSION=0.4.0
#   make release                        # asks
#   DRY_RUN=1 make release BUMP=patch   # everything except publishing
#
# The one rule this exists to enforce: a version number is used once. A
# published tarball's sha256 is baked into the Homebrew formula, so re-cutting
# a version breaks installs for anyone who already resolved it.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION_FILE=Sources/SenseCore/Version.swift
CHANGELOG=CHANGELOG.md
IDENTITY=${IDENTITY:-"Developer ID Application: Adam Koszek (QQ5A9Q7C7Z)"}
BUNDLE_ID=${BUNDLE_ID:-com.koszek.sense}
NOTARY_PROFILE=${NOTARY_PROFILE:-sense-notary}
GITHUB_REPO=${GITHUB_REPO:-wkoszek/sense}
GITEA=${GITEA:-https://tig.koszek.com}
DRY_RUN=${DRY_RUN:-0}

die()  { printf '\033[31mrelease: %s\033[0m\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }

# --- preflight ---------------------------------------------------------------

step "Preflight"

[ -f "$VERSION_FILE" ] || die "$VERSION_FILE not found"

CURRENT=$(sed -n 's/.*senseVersion = "\([^"]*\)".*/\1/p' "$VERSION_FILE")
[ -n "$CURRENT" ] || die "could not parse senseVersion from $VERSION_FILE"
note "current version: $CURRENT"

[ "$(git symbolic-ref --short HEAD)" = "main" ] || die "not on main"
[ -z "$(git status --porcelain)" ] || die "working tree is dirty — commit or stash first"

command -v xcrun >/dev/null || die "xcrun not found (install Xcode command line tools)"
security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY" \
  || die "signing identity not in keychain: $IDENTITY"

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  die "no notarytool credentials stored under profile '$NOTARY_PROFILE'.
    Create it once with:
      xcrun notarytool store-credentials $NOTARY_PROFILE \\
        --apple-id <your-apple-id> --team-id QQ5A9Q7C7Z --password <app-specific-password>
    An app-specific password is made at https://account.apple.com > Sign-In and Security."
fi
note "notary profile '$NOTARY_PROFILE' ok"

# --- resolve the new version -------------------------------------------------

step "Version"

bump() {  # bump <version> <part>
  local IFS=. ; read -r ma mi pa <<< "$1"
  case "$2" in
    major) echo "$((ma+1)).0.0" ;;
    minor) echo "$ma.$((mi+1)).0" ;;
    patch) echo "$ma.$mi.$((pa+1))" ;;
    *) die "unknown bump '$2' (want major|minor|patch)" ;;
  esac
}

if [ -n "${VERSION:-}" ]; then
  NEW=$VERSION
elif [ -n "${BUMP:-}" ]; then
  NEW=$(bump "$CURRENT" "$BUMP")
elif [ ! -r /dev/tty ]; then
  die "no tty to ask on. Pass BUMP=patch|minor|major or VERSION=x.y.z."
else
  echo "    current is $CURRENT. What should this release be?"
  echo "      1) patch -> $(bump "$CURRENT" patch)   fixes only"
  echo "      2) minor -> $(bump "$CURRENT" minor)   new commands or flags"
  echo "      3) major -> $(bump "$CURRENT" major)   breaking CLI changes"
  printf '    choice [1/2/3] or an explicit version: '
  read -r reply </dev/tty
  case "$reply" in
    1|patch) NEW=$(bump "$CURRENT" patch) ;;
    2|minor) NEW=$(bump "$CURRENT" minor) ;;
    3|major) NEW=$(bump "$CURRENT" major) ;;
    [0-9]*)  NEW=$reply ;;
    *) die "no version chosen" ;;
  esac
fi

echo "$NEW" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || die "'$NEW' is not X.Y.Z"
TAG="v$NEW"

# The whole point: never reuse a version. Check locally, on tig (the origin of
# record) and on GitHub (where the tarball the formula pins actually lives).
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
  && die "tag $TAG already exists locally — bump to a new version"
git ls-remote --exit-code --tags tig "refs/tags/$TAG" >/dev/null 2>&1 \
  && die "tag $TAG already exists on tig — bump to a new version"
if _pat=$(opc read -n "op://infra/github-pat-wkoszek/token" 2>/dev/null) && [ -n "$_pat" ]; then
  _code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $_pat" \
    "https://api.github.com/repos/$GITHUB_REPO/releases/tags/$TAG")
  [ "$_code" = 200 ] && die "release $TAG is already published on GitHub — bump to a new version"
  unset _pat
fi

# Refuse to go backwards.
[ "$(printf '%s\n%s\n' "$CURRENT" "$NEW" | sort -V | tail -1)" = "$NEW" ] \
  || die "$NEW is not newer than $CURRENT"
[ "$NEW" != "$CURRENT" ] || die "$NEW is the current version"

note "releasing $CURRENT -> $NEW"

# --- release notes must exist ------------------------------------------------

step "Release notes"

[ -f "$CHANGELOG" ] || die "$CHANGELOG not found"
NOTES=$(awk -v v="## $TAG" '
  $0 ~ "^" v " " || $0 == v {found=1; next}
  found && /^## v/ {exit}
  found {print}
' "$CHANGELOG" | sed '/./,$!d')

[ -n "$NOTES" ] || die "no '## $TAG' section in $CHANGELOG.
    Write the notes first — they become the GitHub release body."
note "$(printf '%s' "$NOTES" | wc -l | tr -d ' ') lines of notes found"

# --- build -------------------------------------------------------------------

step "Building universal binary"

printf '%s\n' \
  '/// Single version string for the whole binary; `sense`, `sense vision` and' \
  '/// `sense audio` all report it so a bug report names one number.' \
  '///' \
  '/// Bumped by scripts/release.sh — do not edit by hand.' \
  "public let senseVersion = \"$NEW\"" > "$VERSION_FILE"

swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/sense
[ -x "$BIN" ] || die "build produced no binary at $BIN"

file "$BIN" | grep -q "universal binary with 2 architectures" \
  || die "binary is not universal"
note "$(file -b "$BIN" | head -1)"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp "$BIN" "$STAGE/sense"

# --- sign --------------------------------------------------------------------

step "Signing"

# A real secure timestamp and the hardened runtime: notarization rejects
# --timestamp=none, which is what `make build` uses for local iteration.
codesign --force --sign "$IDENTITY" \
  --identifier "$BUNDLE_ID" \
  --options runtime --timestamp \
  "$STAGE/sense"

codesign --verify --strict --verbose=2 "$STAGE/sense" 2>&1 | sed 's/^/    /'
codesign -dv --verbose=2 "$STAGE/sense" 2>&1 | grep -E "TeamIdentifier|Identifier=|flags" | sed 's/^/    /'

"$STAGE/sense" --version >/dev/null || die "signed binary does not run"

# --- notarize ----------------------------------------------------------------

step "Notarizing"

TARBALL="sense-$NEW-macos-universal.tar.gz"
ZIP="$STAGE/notarize.zip"
/usr/bin/ditto -c -k --keepParent "$STAGE/sense" "$ZIP"

xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | sed 's/^/    /'

# A standalone Mach-O cannot be stapled (only bundles/dmg/pkg can), so the
# ticket is verified online. Confirm Apple actually accepted it.
if spctl -a -vvv -t install "$STAGE/sense" 2>&1 | grep -q "Notarized Developer ID"; then
  note "gatekeeper: Notarized Developer ID"
else
  spctl -a -vvv -t install "$STAGE/sense" 2>&1 | sed 's/^/    /'
  die "notarization did not take effect"
fi

tar -czf "$TARBALL" -C "$STAGE" sense
SHA=$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)
note "$TARBALL  ($(du -h "$TARBALL" | cut -f1))"
note "sha256 $SHA"

# --- publish -----------------------------------------------------------------

if [ "$DRY_RUN" = 1 ]; then
  step "DRY_RUN=1 — not publishing"
  note "tarball left at ./$TARBALL"
  note "reverting $VERSION_FILE"
  git checkout -- "$VERSION_FILE"
  exit 0
fi

step "Publishing $TAG"
if [ "${YES:-0}" = 1 ]; then
  note "YES=1 — publishing without prompting"
elif [ -r /dev/tty ]; then
  printf '    this creates a public release at github.com/%s. continue? [y/N] ' "$GITHUB_REPO"
  read -r ok </dev/tty
  [ "$ok" = y ] || [ "$ok" = Y ] || die "aborted by user; $VERSION_FILE left modified"
else
  die "no tty to confirm on. Re-run with YES=1 to publish non-interactively."
fi

git add "$VERSION_FILE" "$CHANGELOG"
git commit -m "release: $TAG"
git tag -a "$TAG" -m "$TAG"

GITEA_PAT=$(opc read -n "op://infra/gitea-pat-wkoszek/token")
[ -n "$GITEA_PAT" ] || die "could not read gitea PAT"
git -c "http.$GITEA/.extraHeader=Authorization: token $GITEA_PAT" push tig main
git -c "http.$GITEA/.extraHeader=Authorization: token $GITEA_PAT" push tig "$TAG"
curl -sf -H "Authorization: token $GITEA_PAT" \
  -X POST "$GITEA/api/v1/repos/wkoszek/sense/push_mirrors-sync" >/dev/null \
  && note "mirror synced"

GITHUB_PAT=$(opc read -n "op://infra/github-pat-wkoszek/token")
[ -n "$GITHUB_PAT" ] || die "could not read github PAT"

# Wait for the mirror to carry the tag before the release references it.
for i in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $GITHUB_PAT" \
    "https://api.github.com/repos/$GITHUB_REPO/git/ref/tags/$TAG")
  [ "$code" = 200 ] && break
  [ "$i" = 30 ] && die "tag $TAG never reached GitHub — check the push mirror"
  sleep 4
done
note "tag is on GitHub"

# These must be exported, not passed as argv — `python3 -c "..." VAR=x` makes
# them positional arguments, which os.environ never sees.
RELEASE_ID=$(TAG="$TAG" NOTES="$NOTES" GITHUB_REPO="$GITHUB_REPO" GITHUB_PAT="$GITHUB_PAT" python3 -c "
import json,os,urllib.request
body=json.dumps({'tag_name':os.environ['TAG'],'name':os.environ['TAG'],
                 'body':os.environ['NOTES'],'draft':False,'prerelease':False}).encode()
r=urllib.request.Request('https://api.github.com/repos/'+os.environ['GITHUB_REPO']+'/releases',
    data=body, method='POST',
    headers={'Authorization':'Bearer '+os.environ['GITHUB_PAT'],
             'Accept':'application/vnd.github+json'})
print(json.load(urllib.request.urlopen(r))['id'])
")
note "created release $RELEASE_ID"

curl -sf -X POST \
  -H "Authorization: Bearer $GITHUB_PAT" \
  -H "Content-Type: application/gzip" \
  --data-binary @"$TARBALL" \
  "https://uploads.github.com/repos/$GITHUB_REPO/releases/$RELEASE_ID/assets?name=$TARBALL" \
  >/dev/null && note "uploaded $TARBALL"

# --- formula -----------------------------------------------------------------

step "Homebrew formula"
cat <<EOF
    Update wkoszek/homebrew-tap Formula/sense.rb with:

      url "https://github.com/$GITHUB_REPO/releases/download/$TAG/$TARBALL"
      sha256 "$SHA"
      version "$NEW"

    Then:  brew update && brew upgrade sense
EOF

step "Released $TAG"
note "https://github.com/$GITHUB_REPO/releases/tag/$TAG"
