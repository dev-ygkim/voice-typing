#!/bin/bash
# 이 Mac 의 로그인 키체인에 Voice Typing 전용 자체 서명 코드 서명 인증서를 한 번 만든다.
#   임시(ad-hoc) 서명은 빌드할 때마다 앱 지문이 바뀌어, 설치할 때마다 손쉬운 사용 권한이 풀린다.
#   이 인증서로 서명하면 다시 빌드·설치해도 macOS 가 같은 앱으로 알아봐 권한이 유지된다.
#   인증서와 개인 키는 이 Mac 키체인에만 있고 저장소에는 올라가지 않는다. build.sh 가 있으면 알아서 쓴다.
# 사용: ./make-signing-cert.sh   (이미 있으면 아무것도 하지 않는다)
# 지우기: security delete-identity -c "Voice Typing Local Signing"
set -euo pipefail

NAME="Voice Typing Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "이미 있습니다: $NAME"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=$(/usr/bin/openssl rand -hex 16)   # 키체인으로 옮기는 동안만 쓰는 임시 암호
# macOS 기본 openssl(LibreSSL) 을 쓴다. 다른 openssl 이 만든 p12 는 키체인이 못 읽을 수 있다.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$NAME" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
/usr/bin/openssl pkcs12 -export -name "$NAME" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -passout "pass:$PASS" -out "$TMP/identity.p12"
# -T: codesign 이 키체인 확인 창 없이 이 키를 쓸 수 있게 한다
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null

echo "만들었습니다: $NAME"
