#!/bin/bash
# FanPilot install / update in one line:
#
#   curl -fsSL https://raw.githubusercontent.com/flowerjun/FanPilot/main/scripts/get.sh | bash
#
# Downloads the latest release, checks it against the SHA-256 GitHub publishes, and copies
# FanPilot.app into /Applications. Files fetched with curl carry no quarantine flag, so the app
# opens without the "Open Anyway" step. If the fan service is already installed it is updated
# too (asks for your password once); on a fresh install the app offers to install it.
set -euo pipefail

REPO=flowerjun/FanPilot
DEST=/Applications/FanPilot.app
BUNDLE_ID=com.flowerjun.fanpilot
PLIST=/Library/LaunchDaemons/$BUNDLE_ID.plist

say() { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

[[ $(uname) == Darwin ]] || fail "FanPilot은 macOS 전용입니다 / FanPilot is for macOS only."

WORK=$(mktemp -d)
MNT=$WORK/mnt
cleanup() { hdiutil detach -quiet -force "$MNT" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

say "최신 버전 확인 / Checking the latest release…"
curl -fsSL -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$REPO/releases/latest" -o "$WORK/release.json"
# plutil reads JSON, so no extra tools are needed.
field() { plutil -extract "$1" raw -o - "$WORK/release.json" 2>/dev/null; }
TAG=$(field tag_name) || fail "릴리즈 정보를 읽지 못했습니다 / Couldn't read the release."
URL="" SHA=""
for i in $(seq 0 20); do
    NAME=$(field "assets.$i.name") || break
    if [[ $NAME == FanPilot.dmg ]]; then
        URL=$(field "assets.$i.browser_download_url")
        SHA=$(field "assets.$i.digest" || true); SHA=${SHA#sha256:}
        break
    fi
done
[[ -n $URL && -n $SHA ]] || fail "릴리즈에 확인 가능한 DMG가 없습니다 / The release has no verifiable DMG."

say "FanPilot ${TAG#v} 내려받는 중 / Downloading…"
curl -fL --progress-bar "$URL" -o "$WORK/FanPilot.dmg"
[[ $(shasum -a 256 "$WORK/FanPilot.dmg" | awk '{print $1}') == "$SHA" ]] \
    || fail "SHA-256이 맞지 않습니다. 설치를 중단합니다 / SHA-256 mismatch, aborting."
echo "SHA-256 OK"

hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$MNT" "$WORK/FanPilot.dmg"
NEW=$MNT/FanPilot.app
[[ $(defaults read "$NEW/Contents/Info.plist" CFBundleIdentifier) == "$BUNDLE_ID" ]] || fail "DMG 안의 앱이 올바르지 않습니다 / Unexpected app in the DMG."

# Quit a running copy first; replacing a running app can leave it half-updated.
if pgrep -xq FanPilot; then
    say "실행 중인 FanPilot 종료 / Quitting FanPilot…"
    osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
    for _ in $(seq 1 50); do pgrep -xq FanPilot || break; sleep 0.2; done
fi

if [[ -f $PLIST ]]; then
    # Service installed: the bundled admin script replaces the app and updates the service.
    say "앱과 팬 제어 서비스 업데이트 (관리자 암호) / Updating app and fan service (admin password)…"
    sudo /bin/zsh "$NEW/Contents/Resources/fanpilot-admin.sh" update "$NEW" "$(id -un)" "$DEST" < /dev/tty
else
    say "/Applications에 복사 / Copying to /Applications…"
    if [[ -w /Applications && ( ! -e $DEST || -w $DEST ) ]]; then
        rm -rf "$DEST"; ditto "$NEW" "$DEST"; xattr -cr "$DEST"
    else
        sudo /bin/sh -c 'rm -rf "$1" && ditto "$2" "$1" && xattr -cr "$1" && chown -R "$3":staff "$1"' _ "$DEST" "$NEW" "$(id -un)" < /dev/tty
    fi
fi

open "$DEST"
say "FanPilot ${TAG#v} 설치 완료 / installed."
