#!/bin/bash
# Voice Typing 앱을 빌드한다.
#   결과: build/Voice Typing.app, dist/VoiceTyping-<버전>.dmg
#   버전: 이 폴더의 VERSION 파일(예: 1.0.0)이 기준이다. 버전을 올리려면 VERSION 을 고치고 다시 빌드한다.
# 사용: ./build.sh          빌드 + dmg 생성
#       ./build.sh --open   빌드 후 build/ 의 앱을 바로 실행 (개발용)
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(tr -d '[:space:]' < VERSION)
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "VERSION 파일 형식이 잘못되었습니다: '$VERSION' (예: 1.0.0)" >&2
    exit 1
fi

swift build -c release

APP="build/Voice Typing.app"
rm -rf build/*.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/VoiceTyping "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
# 앱 아이콘 (원본: docs/assets/icons/icon-c-bubble-hangul.svg)
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
                        -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
# 자체 서명 인증서 이름을 VOICETYPING_SIGN_ID 로 주면 재빌드해도 손쉬운 사용 권한이 유지된다. 없으면 임시(ad-hoc) 서명.
codesign --force --sign "${VOICETYPING_SIGN_ID:--}" "$APP"

# 디스크 이미지: 앱 + Applications 바로가기 (Finder 에서 끌어다 놓아 설치할 수도 있다)
DMG="dist/VoiceTyping-$VERSION.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Voice Typing.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p dist
rm -f "$DMG"
hdiutil create -quiet -volname "Voice Typing $VERSION" -srcfolder "$STAGE" -format UDZO "$DMG"

echo "빌드 완료: $APP (v$VERSION)"
echo "설치 파일: $DMG"

if [[ "${1:-}" == "--open" ]]; then
    pkill -x VoiceTyping || true
    # 이전 프로세스가 완전히 끝나기 전에 열면 LaunchServices 가 -600 오류를 낸다
    while pgrep -x VoiceTyping >/dev/null; do sleep 0.2; done
    # -g: 지금 쓰는 창의 포커스를 빼앗지 않게 뒤에서 실행.
    # 방금 끝낸 프로세스를 LaunchServices 가 잠깐 기억해 -600 이 날 수 있어 몇 번 다시 시도한다.
    for _ in 1 2 3 4 5; do open -g "$APP" 2>/dev/null && break; sleep 0.5; done
fi
