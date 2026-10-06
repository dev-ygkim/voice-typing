#!/bin/bash
# Voice Typing 을 /Applications 에 설치하고 실행한다.
# 사용: ./install.sh              ./build.sh 로 빌드한 뒤 만든 dmg 로 설치
#       ./install.sh 파일.dmg     이미 있는 dmg 로 설치
# 참고: 임시(ad-hoc) 서명이라 다시 설치하면 마이크·손쉬운 사용 권한을 다시 물을 수 있다.
set -euo pipefail

if [[ $# -ge 1 ]]; then
    DMG="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
    cd "$(dirname "$0")"
else
    cd "$(dirname "$0")"
    ./build.sh
    DMG="dist/VoiceTyping-$(tr -d '[:space:]' < VERSION).dmg"
fi
[[ -f "$DMG" ]] || { echo "dmg 파일이 없습니다: $DMG" >&2; exit 1; }

MOUNT=$(mktemp -d)
# -nobrowse: Finder 창을 띄우지 않는다
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT" "$DMG"
trap 'hdiutil detach -quiet "$MOUNT" || true; rmdir "$MOUNT" 2>/dev/null || true' EXIT

# 실행 중인 Voice Typing(개발용 포함)을 끝내고 설치본을 바꾼다
pkill -x VoiceTyping || true
while pgrep -x VoiceTyping >/dev/null; do sleep 0.2; done
DEST="/Applications/Voice Typing.app"
rm -rf "$DEST"
ditto "$MOUNT/Voice Typing.app" "$DEST"
touch "$DEST"      # Finder 가 예전 아이콘을 캐시해 두었으면 새로 읽게 한다

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$DEST/Contents/Info.plist")
# -g: 지금 쓰는 창의 포커스를 빼앗지 않게 뒤에서 실행.
# 방금 끝낸 프로세스를 LaunchServices 가 잠깐 기억해 -600 이 날 수 있어 몇 번 다시 시도한다.
for _ in 1 2 3 4 5; do open -g "$DEST" 2>/dev/null && break; sleep 0.5; done
echo "설치 완료: $DEST (v$VERSION) — 메뉴바의 🎙 아이콘을 누르세요"
