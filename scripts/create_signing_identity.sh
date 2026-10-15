#!/bin/bash
# 実行にはユーザーの明示承認が必要。MenuDrawer専用の署名を作る一度限りの手順。
set -euo pipefail
identity_label='MenuDrawer Local Signing'
keychain_path=$(security default-keychain -d user | tr -d '"' | sed 's/^[[:space:]]*//')
if security find-certificate -c "$identity_label" "$keychain_path" >/dev/null 2>&1; then
    printf '同名の証明書が存在します。重複作成はしません。\n' >&2
    exit 1
fi
signing_stage=$(mktemp -d "${TMPDIR:-/tmp}/menudrawer-signing.XXXXXX")
chmod 700 "$signing_stage"
imported=0
fingerprint=''
cleanup() {
    result=$?
    if [[ "$result" != 0 && "$imported" == 1 && -n "$fingerprint" ]]; then
        security remove-trusted-cert "$signing_stage/cert.pem" >/dev/null 2>&1 || true
        if ! security delete-identity -Z "$fingerprint" "$keychain_path" >/dev/null 2>&1; then
            printf '署名準備に失敗しました。キーチェーン内の「MenuDrawer Local Signing」の削除を確認してください。\n' >&2
        fi
    fi
    rm -rf "$signing_stage"
    exit "$result"
}
trap cleanup EXIT
cat > "$signing_stage/openssl.cnf" <<'CFG'
[req]
distinguished_name = subject
x509_extensions = extensions
prompt = no
[subject]
CN = MenuDrawer Local Signing
[extensions]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CFG
umask 077
/usr/bin/openssl req -new -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 -config "$signing_stage/openssl.cnf" -keyout "$signing_stage/key.pem" -out "$signing_stage/cert.pem" >/dev/null 2>&1
# macOSのPKCS#12読み込みと互換性のある形式で、一時パスワードを付ける。
MENUDRAWER_P12_PASSWORD=$(/usr/bin/openssl rand -hex 24)
export MENUDRAWER_P12_PASSWORD
/usr/bin/openssl pkcs12 -export -inkey "$signing_stage/key.pem" -in "$signing_stage/cert.pem" -out "$signing_stage/identity.p12" -passout env:MENUDRAWER_P12_PASSWORD -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 -name "$identity_label"
/usr/bin/openssl pkcs12 -in "$signing_stage/identity.p12" -passin env:MENUDRAWER_P12_PASSWORD -noout
fingerprint=$(/usr/bin/openssl x509 -in "$signing_stage/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')
security import "$signing_stage/identity.p12" -k "$keychain_path" -P "$MENUDRAWER_P12_PASSWORD" -T /usr/bin/codesign
unset MENUDRAWER_P12_PASSWORD
imported=1
# 通信・TLS用の信頼は付与しない。コード署名の用途だけを対象にする。
security add-trusted-cert -r trustRoot -p codeSign -k "$keychain_path" "$signing_stage/cert.pem"
security find-identity -v -p codesigning | rg -F "$identity_label"
printf '署名用証明書・鍵をキーチェーンへ保存しました。一時ファイルは削除します。\n'
