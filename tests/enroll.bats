#!/usr/bin/env bats
#
# Handing one device its way in. The authority itself is stubbed here — it has
# tests of its own (ca.bats) — and what is under test is the part that decides
# what gets published, where, and for how long:
#
#  - a link nobody can guess, and only one file behind it;
#  - a removal that is scheduled before the link is handed out, not after;
#  - nothing published at all when the authority refuses.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../ansible/roles/expose/files/roost-enroll"
    STUB_DIR="$BATS_TEST_TMPDIR/stub"
    mkdir -p "$STUB_DIR" "$BATS_TEST_TMPDIR/enroll" "$BATS_TEST_TMPDIR/clients"

    # The authority: prints what the real one prints, and puts a file where it
    # says it did.
    cat > "$STUB_DIR/roost-ca" <<EOF
#!/usr/bin/env bash
[ "\$1" = issue ] || { echo "unexpected: \$*" >&2; exit 64; }
if [ "\$2" = refused ]; then echo "roost-ca: openssl ca refused to sign" >&2; exit 1; fi
printf 'bundle for %s\n' "\$2" > "$BATS_TEST_TMPDIR/clients/\$2.p12"
echo "file=$BATS_TEST_TMPDIR/clients/\$2.p12"
echo "password=hunter2hunter"
EOF
    chmod +x "$STUB_DIR/roost-ca"

    # systemd-run, so the test can see what was scheduled without scheduling it.
    cat > "$STUB_DIR/systemd-run" <<EOF
#!/usr/bin/env bash
echo "systemd-run \$*" >> "$BATS_TEST_TMPDIR/scheduled"
EOF
    chmod +x "$STUB_DIR/systemd-run"

    PATH="$STUB_DIR:$PATH"
    export PATH
    export ROOST_CA_BIN="$STUB_DIR/roost-ca"
    export ROOST_ENROLL_DIR="$BATS_TEST_TMPDIR/enroll"
    export ROOST_EXPOSE_STATE="$BATS_TEST_TMPDIR/expose.env"
    export ROOST_ENROLL_TTL=42
    printf 'EXPOSE_URL=https://stand.example:8443\n' > "$ROOST_EXPOSE_STATE"
}

@test "a device is given a link under the published address" {
    run "$SCRIPT" phone
    [ "$status" -eq 0 ]
    [[ "$output" == *"url=https://stand.example:8443/roost-enroll/"* ]]
    [[ "$output" == *"password=hunter2hunter"* ]]
    [[ "$output" == *"expires=42 seconds"* ]]
}

@test "the published name says nothing about the device" {
    run "$SCRIPT" phone
    # Guessable names are the whole risk here: this directory is served without a
    # certificate, because the phone being enrolled has not got one yet.
    [[ "$output" != *"phone.p12"* ]]
    local published
    published="$(ls "$ROOST_ENROLL_DIR")"
    [[ "$published" =~ ^[0-9a-f]{32}\.p12$ ]]
}

@test "exactly one file is published, and it is the bundle" {
    run "$SCRIPT" phone
    [ "$(ls "$ROOST_ENROLL_DIR" | wc -l)" -eq 1 ]
    [ "$(cat "$ROOST_ENROLL_DIR"/*.p12)" = "bundle for phone" ]
}

@test "the bundle is readable by the front, and not writable by it" {
    run "$SCRIPT" phone
    [ "$(stat -c '%a' "$ROOST_ENROLL_DIR"/*.p12)" = 644 ]
}

@test "its removal is scheduled before the link is printed" {
    run "$SCRIPT" phone
    [ -f "$BATS_TEST_TMPDIR/scheduled" ]
    grep -q -- "--on-active=42" "$BATS_TEST_TMPDIR/scheduled"
    grep -q "$ROOST_ENROLL_DIR" "$BATS_TEST_TMPDIR/scheduled"
}

# A link that never expires is the failure this exists to prevent, so a machine
# that cannot schedule the removal must not publish the link either.
@test "a scheduler that fails means nothing is handed out" {
    printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB_DIR/systemd-run"
    chmod +x "$STUB_DIR/systemd-run"
    run "$SCRIPT" phone
    [ "$status" -ne 0 ]
    [[ "$output" == *"removal"* ]]
}

@test "an authority that refuses leaves nothing published" {
    run "$SCRIPT" refused
    [ "$status" -ne 0 ]
    [ -z "$(ls -A "$ROOST_ENROLL_DIR")" ]
}

@test "no published address means there is nowhere to send anybody" {
    : > "$ROOST_EXPOSE_STATE"
    run "$SCRIPT" phone
    [ "$status" -ne 0 ]
    [[ "$output" == *"roost expose"* ]]
}

@test "no device name is a question, not a guess" {
    run "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"which device"* ]]
}
