#!/usr/bin/env bats
#
# The authority behind the client-certificate lock. Real openssl against a
# throwaway directory, because an authority is state and state that only exists
# after a successful ansible run is state nobody can test — the script is written
# to take its directory from the environment for exactly this reason.
#
# What nginx then does with what this produces is tests/integration/mtls_container.sh.

setup() {
    command -v openssl >/dev/null || skip "openssl is not installed"
    CA="$BATS_TEST_DIRNAME/../ansible/roles/expose/files/roost-ca"
    export ROOST_CA_DIR="$BATS_TEST_TMPDIR/ca"
    mkdir -p "$ROOST_CA_DIR"
}

issue() {
    run "$CA" issue "$1"
    [ "$status" -eq 0 ]
    P12="$(sed -n 's/^file=//p' <<<"$output")"
    PASS="$(sed -n 's/^password=//p' <<<"$output")"
}

@test "an authority is created once, and saying so again changes nothing" {
    run "$CA" init
    [ "$status" -eq 0 ]
    [ -f "$ROOST_CA_DIR/ca.crt" ]
    local before; before="$(sha256sum "$ROOST_CA_DIR/ca.crt")"
    run "$CA" init
    [ "$status" -eq 0 ]
    [[ "$output" == *"already"* ]]
    [ "$before" = "$(sha256sum "$ROOST_CA_DIR/ca.crt")" ]
}

# The one file on the machine that can mint a way into the terminal.
@test "the authority's key is readable by nobody else" {
    "$CA" init >/dev/null
    [ "$(stat -c '%a' "$ROOST_CA_DIR/ca.key")" = 600 ]
    [ "$(stat -c '%a' "$ROOST_CA_DIR")" = 700 ]
    # Its certificate and revocation list are public by nature — the front reads
    # them after dropping privileges.
    [ "$(stat -c '%a' "$ROOST_CA_DIR/ca.crt")" = 644 ]
    [ "$(stat -c '%a' "$ROOST_CA_DIR/ca.crl")" = 644 ]
}

@test "a device gets a bundle that opens with the password it was given" {
    "$CA" init >/dev/null
    issue phone
    [ -f "$P12" ]
    [ -n "$PASS" ]
    run openssl pkcs12 -in "$P12" -passin "pass:$PASS" -info -noout
    [ "$status" -eq 0 ]
}

# The measurement behind "the certificate cannot travel in a QR code": a code
# holds 2953 bytes and this is comfortably past it. If a future change made the
# bundle small enough, this test failing is the right way to find out.
@test "a bundle is bigger than a QR code can carry" {
    "$CA" init >/dev/null
    issue phone
    [ "$(stat -c '%s' "$P12")" -gt 2953 ]
}

@test "the bundle is readable by a modern importer, not by a legacy one" {
    "$CA" init >/dev/null
    issue phone
    # `-legacy` produces a bundle whose certificate bag is 40-bit RC2: openssl 3
    # cannot read it back without its legacy provider and current phones are
    # dropping it. What is wanted is AES with an SHA-256 MAC.
    run openssl pkcs12 -in "$P12" -passin "pass:$PASS" -info -noout
    [[ "$output" == *"AES-256-CBC"* ]]
    [[ "$output" == *"sha256"* ]]
    [[ "$output" != *"RC2"* ]]
}

@test "the wrong password does not open it" {
    "$CA" init >/dev/null
    issue phone
    run openssl pkcs12 -in "$P12" -passin "pass:nonsense" -info -noout
    [ "$status" -ne 0 ]
}

@test "the device's certificate is for a client, and this authority signed it" {
    "$CA" init >/dev/null
    issue phone
    openssl pkcs12 -in "$P12" -passin "pass:$PASS" -nokeys -clcerts \
        -out "$BATS_TEST_TMPDIR/phone.pem" 2>/dev/null
    run openssl x509 -in "$BATS_TEST_TMPDIR/phone.pem" -noout -ext extendedKeyUsage
    [[ "$output" == *"Client Authentication"* ]]
    run openssl verify -CAfile "$ROOST_CA_DIR/ca.crt" "$BATS_TEST_TMPDIR/phone.pem"
    [ "$status" -eq 0 ]
}

@test "two devices are two certificates" {
    "$CA" init >/dev/null
    issue phone
    issue laptop
    run "$CA" list
    [[ "$output" == *"valid      phone"* ]]
    [[ "$output" == *"valid      laptop"* ]]
}

@test "a revoked device is named as revoked, and its bundle is gone" {
    "$CA" init >/dev/null
    issue phone
    local p12="$P12"
    run "$CA" revoke phone
    [ "$status" -eq 0 ]
    run "$CA" list
    [[ "$output" == *"revoked    phone"* ]]
    # A .p12 whose certificate is revoked is a file that looks like a way in.
    [ ! -f "$p12" ]
}

@test "revocation reaches the list the front reads" {
    "$CA" init >/dev/null
    issue phone
    local serial
    openssl pkcs12 -in "$P12" -passin "pass:$PASS" -nokeys -clcerts \
        -out "$BATS_TEST_TMPDIR/phone.pem" 2>/dev/null
    serial="$(openssl x509 -in "$BATS_TEST_TMPDIR/phone.pem" -noout -serial | cut -d= -f2)"
    "$CA" revoke phone >/dev/null
    run openssl crl -in "$ROOST_CA_DIR/ca.crl" -noout -text
    [[ "$output" == *"$serial"* ]]
}

@test "revoking a device nobody issued is an error, not a silent success" {
    "$CA" init >/dev/null
    run "$CA" revoke ghost
    [ "$status" -ne 0 ]
    [[ "$output" == *"no certificate"* ]]
}

@test "issuing before there is an authority says which command is missing" {
    run "$CA" issue phone
    [ "$status" -ne 0 ]
    [[ "$output" == *"init"* ]]
}

# The name becomes a file name and a certificate subject.
@test "a device name that would escape the directory is refused" {
    "$CA" init >/dev/null
    run "$CA" issue "../../etc/shadow"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a usable device name"* ]]
    run "$CA" issue ".hidden"
    [ "$status" -ne 0 ]
}

@test "no device name at all is a question, not a guess" {
    "$CA" init >/dev/null
    run "$CA" issue
    [ "$status" -ne 0 ]
    [[ "$output" == *"which device"* ]]
}

@test "an unknown subcommand prints what there is" {
    run "$CA" frobnicate
    [ "$status" -ne 0 ]
    [[ "$output" == *"usage"* ]]
}
