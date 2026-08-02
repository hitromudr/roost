#!/usr/bin/env bats
#
# The roost wrapper is what a user actually types. These tests cover the
# parts that do not need a machine: reading and writing the config, refusing
# to publish without authentication, and what doctor concludes from a given
# state. Applying roles is covered by the container tests.

setup() {
    ROOST="$BATS_TEST_DIRNAME/../roost"
    export ROOST_CONF="$BATS_TEST_TMPDIR/roost.conf"
    STUB_DIR="$BATS_TEST_TMPDIR/stub"
    mkdir -p "$STUB_DIR"
    for tool in ansible-playbook ansible-galaxy systemctl tmux; do
        printf '#!/usr/bin/env bash\necho "%s $*" >> "$STUB_LOG"\nexit ${STUB_RC:-0}\n' "$tool" \
            > "$STUB_DIR/$tool"
        chmod +x "$STUB_DIR/$tool"
    done
    PATH="$STUB_DIR:$PATH"
    export PATH STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
    : > "$STUB_LOG"
}

write_conf() {
    cat > "$ROOST_CONF" <<EOF
egress_profile=pinned
agent_command=/usr/local/bin/claude
gate_host=${1-}
gate_domain=${2-}
auth=${3-mtls}
EOF
}

@test "help is printed without a config and without failing" {
    run "$ROOST" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"install"* ]]
    [[ "$output" == *"doctor"* ]]
}

@test "an unknown command fails with a usage hint" {
    run "$ROOST" frobnicate
    [ "$status" -ne 0 ]
    [[ "$output" == *"frobnicate"* ]]
}

@test "install without a config asks to run the wizard" {
    run "$ROOST" install
    [ "$status" -ne 0 ]
    [[ "$output" == *"setup"* || "$output" == *"roost.conf"* ]]
}

@test "install passes the config through to ansible as variables" {
    write_conf "" "" mtls
    run "$ROOST" install
    [ "$status" -eq 0 ]
    grep -q "ansible-playbook" "$STUB_LOG"
    grep -q "egress_sandbox_profile=pinned" "$STUB_LOG"
}

@test "publishing without authentication is refused" {
    write_conf gate.example cc.example none
    run "$ROOST" install
    [ "$status" -ne 0 ]
    # A terminal exposed to the internet with no authentication is the one
    # mistake this tool must not let you make quietly.
    [[ "$output" == *"auth"* ]]
}

@test "a gate host without a domain is refused" {
    write_conf gate.example "" mtls
    run "$ROOST" install
    [ "$status" -ne 0 ]
    [[ "$output" == *"domain"* ]]
}

@test "doctor reports on a machine where nothing is installed" {
    write_conf "" "" mtls
    STUB_RC=1 run "$ROOST" doctor
    # Nothing installed is a finding, not a crash.
    [ "$status" -ne 0 ]
    [[ "$output" == *"egress"* ]]
}

@test "doctor names the fix, not just the symptom" {
    write_conf "" "" mtls
    STUB_RC=1 run "$ROOST" doctor
    [[ "$output" == *"roost install"* ]]
}
