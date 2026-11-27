#!/bin/bash
# 로컬 빌드용 고정 코드서명 identity 생성 (1회).
#
# 왜: ad-hoc 서명은 빌드마다 서명이 바뀌어 키체인 ACL·TCC(알림 등) 승인이
# 리셋된다. 고정 self-signed identity로 서명하면 리빌드해도 승인이 유지된다.
# unlock-keychain 자동화·암호 저장은 하지 않는다 — 신뢰 등록 시 macOS가
# 사용자 암호를 1회 물어보는 것이 정상이다.
#
# 사용: scripts/setup-signing.sh   (identity 이름 기본 "TokenCat Dev")
set -euo pipefail

IDENTITY="${1:-TokenCat Dev}"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  echo "✓ 이미 존재: $IDENTITY"
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "▸ self-signed 코드서명 인증서 생성: $IDENTITY (10년)"
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -nodes -subj "/CN=$IDENTITY" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:FALSE" 2>/dev/null

# p12로 묶어 로그인 키체인에 임포트 (-T: codesign이 키를 쓰도록 사전 승인)
# OpenSSL 3의 기본 AES-PKCS12는 macOS 임포터가 못 읽음 → 레거시 알고리즘 우선
openssl pkcs12 -export -legacy -out "$TMP/cert.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$IDENTITY" \
  -passout pass:runtime-import 2>/dev/null \
|| openssl pkcs12 -export -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
  -out "$TMP/cert.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$IDENTITY" \
  -passout pass:runtime-import 2>/dev/null \
|| openssl pkcs12 -export -out "$TMP/cert.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$IDENTITY" \
  -passout pass:runtime-import   # LibreSSL(맥 기본)은 기본값이 레거시 호환
security import "$TMP/cert.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P runtime-import -T /usr/bin/codesign > /dev/null

# -T만으로는 macOS 10.12 뒤의 파티션 검사에 걸려 codesign이 키를 쓸 때마다 묻고, 자리를 비운 사이 자동 업데이트가
# 그 창에 막혀 errSecInternalComponent로 실패한다. 파티션까지 열어 두면 [항상 허용]을 누른 것과 같다.
# 로그인 암호를 한 번 묻는다. 건너뛰면 처음 서명할 때 뜨는 키체인 창에서 [항상 허용]을 누르면 된다
echo "▸ codesign이 묻지 않고 서명하게 허용 — 로그인 암호를 물으면 입력하세요 (1회)"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -l "$IDENTITY" \
  "$HOME/Library/Keychains/login.keychain-db" > /dev/null \
  || echo "  건너뜀: 처음 서명할 때 키체인 창이 뜨면 [항상 허용]을 누르세요"

echo "▸ 코드서명 신뢰 등록 — macOS가 로그인 암호를 물어보면 승인해주세요 (1회)"
security add-trusted-cert -r trustRoot -p codeSign \
  -k "$HOME/Library/Keychains/login.keychain-db" "$TMP/cert.pem"

echo "✓ 완료:"
security find-identity -v -p codesigning | grep "$IDENTITY"
