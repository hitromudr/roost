#!/usr/bin/env bats
#
# agent-run is what actually launches the agent inside the sandbox group.
# The tests stub `sg` so the launcher can be exercised without the group
# existing and without running an agent.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../ansible/roles/egress_sandbox/files/agent-run"
    STUB_DIR="$BATS_TEST_TMPDIR/stub"
    mkdir -p "$STUB_DIR"
    # The stub stands in for sg: it reports the group, then runs the command
    # line through a shell exactly as sg would. Going through eval is what
    # makes the quoting testable — a naive echo would pass even if arguments
    # with spaces were mangled.
    cat > "$STUB_DIR/sg" <<'EOF'
#!/usr/bin/env bash
echo "sg-called group=$1"
shift
[ "$1" = "-c" ] && shift
eval "printf 'arg=[%s]\n' $1"
EOF
    chmod +x "$STUB_DIR/sg"
    PATH="$STUB_DIR:$PATH"
    export PATH

    ENV_FILE="$BATS_TEST_TMPDIR/proxy.env"
    export AGENT_ENV_FILE="$ENV_FILE"
    export AGENT_GROUP=agent-sandbox
    export AGENT_COMMAND=/usr/bin/true
    # Never read the real machine's configuration during a test.
    export AGENT_CONFIG="$BATS_TEST_TMPDIR/absent.env"
}

@test "configuration is read from the config file" {
    cat > "$BATS_TEST_TMPDIR/agent-run.env" <<EOF
AGENT_GROUP=from-file
AGENT_COMMAND=/usr/bin/true
AGENT_ENV_FILE=$ENV_FILE
EOF
    run env -u AGENT_GROUP -u AGENT_COMMAND \
        AGENT_CONFIG="$BATS_TEST_TMPDIR/agent-run.env" "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sg-called group=from-file"* ]]
}

@test "the environment overrides the config file" {
    cat > "$BATS_TEST_TMPDIR/agent-run.env" <<EOF
AGENT_GROUP=from-file
AGENT_COMMAND=/usr/bin/true
EOF
    run env AGENT_GROUP=from-env \
        AGENT_CONFIG="$BATS_TEST_TMPDIR/agent-run.env" "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sg-called group=from-env"* ]]
}

@test "launches the agent through sg in the sandbox group" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sg-called group=agent-sandbox"* ]]
    [[ "$output" == *"/usr/bin/true"* ]]
}

@test "arguments reach the agent, quoted" {
    run "$SCRIPT" --flag "two words"
    [ "$status" -eq 0 ]
    [[ "$output" == *"arg=[--flag]"* ]]
    # One argument, not two: the space must survive the trip through sg.
    [[ "$output" == *"arg=[two words]"* ]]
}

@test "proxy settings come from the env file, not from the script" {
    cat > "$ENV_FILE" <<'EOF'
PROXY_URL=http://user:secret@127.0.0.1:8129
EOF
    chmod 600 "$ENV_FILE"
    run env AGENT_DEBUG_ENV=1 "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"HTTPS_PROXY=http://user:secret@127.0.0.1:8129"* ]]
    [[ "$output" == *"NO_PROXY=localhost,127.0.0.1"* ]]
    # The script itself must stay free of credentials.
    ! grep -q "secret" "$SCRIPT"
}

@test "runs without an env file, for the direct profile" {
    rm -f "$ENV_FILE"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sg-called"* ]]
}

@test "refuses a world-readable env file" {
    cat > "$ENV_FILE" <<'EOF'
PROXY_URL=http://user:secret@127.0.0.1:8129
EOF
    chmod 644 "$ENV_FILE"
    run "$SCRIPT"
    # Credentials in a file everybody can read is a misconfiguration worth
    # stopping for, not a warning to scroll past.
    [ "$status" -ne 0 ]
    [[ "$output" == *"permissions"* || "$output" == *"0600"* ]]
}
