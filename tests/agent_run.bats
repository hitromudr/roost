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
    # Nor the rest of what a stand puts in the environment. agent-run exports
    # every AGENT_* variable it reads, so a suite run from inside a roost
    # session inherits them — and the environment outranks the config file by
    # design. Without this, the tests that prove the file is read pass in CI
    # and fail on the machine the roles manage, which is the one place the
    # answer matters.
    unset AGENT_PROFILE AGENT_DIR AGENT_DEBUG_ENV

    # The normal state of a stand: a proxy is configured. Tests about its
    # absence remove or rewrite this file themselves.
    printf 'PROXY_URL=http://user:secret@127.0.0.1:8129\n' > "$ENV_FILE"
    chmod 640 "$ENV_FILE"
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

@test "destinations the firewall lets through directly bypass the proxy" {
    # The proxied profile opens these to the agent without the proxy, and the
    # proxy has no route to them (a LAN host answered 502 through it, 200
    # directly) — so they belong in NO_PROXY, not behind the proxy.
    printf 'PROXY_URL=http://user:secret@127.0.0.1:8129\n' > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    run env AGENT_DEBUG_ENV=1 AGENT_PROFILE=proxied AGENT_DIRECT="192.168.0.0/16 10.1.2.3" "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"NO_PROXY=localhost,127.0.0.1,192.168.0.0/16,10.1.2.3"* ]]
}

@test "the pinned profile keeps only loopback off the proxy" {
    printf 'PROXY_URL=http://user:secret@127.0.0.1:8129\n' > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    run env AGENT_DEBUG_ENV=1 AGENT_PROFILE=pinned AGENT_DIRECT="192.168.0.0/16" "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"NO_PROXY=localhost,127.0.0.1"* ]]
    [[ "$output" != *"192.168"* ]]
}

@test "runs without an env file, for the direct profile" {
    rm -f "$ENV_FILE"
    run env AGENT_PROFILE=direct "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sg-called"* ]]
}

@test "refuses to start with no proxy on a profile that needs one" {
    # The rules would normally stop this agent anyway. "Normally" is not good
    # enough when one request from an unexpected address costs the account:
    # two things now have to fail before a packet leaves directly.
    rm -f "$ENV_FILE"
    run "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no PROXY_URL"* ]]
    [[ "$output" != *"sg-called"* ]]
}

@test "an env file that lost its PROXY_URL stops the agent" {
    printf '# someone commented it out\n' > "$ENV_FILE"
    chmod 640 "$ENV_FILE"
    run "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no PROXY_URL"* ]]
    [[ "$output" == *"$ENV_FILE"* ]]
}

@test "the profile comes from the config file too" {
    cat > "$BATS_TEST_TMPDIR/agent-run.env" <<EOF
AGENT_GROUP=agent-sandbox
AGENT_COMMAND=/usr/bin/true
AGENT_PROFILE=direct
EOF
    rm -f "$ENV_FILE"
    run env -u AGENT_GROUP -u AGENT_COMMAND -u AGENT_ENV_FILE \
        AGENT_CONFIG="$BATS_TEST_TMPDIR/agent-run.env" "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sg-called"* ]]
}

@test "accepts a group-readable env file" {
    cat > "$ENV_FILE" <<EOF
PROXY_URL=http://user:secret@127.0.0.1:8129
EOF
    chmod 640 "$ENV_FILE"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
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

# --- a second agent -----------------------------------------------------
# The launcher's own name selects the agent, so a second agent costs a symlink
# and a one-line file instead of a second wrapper with its own copy of the
# group, the proxy and the profile.

@test "a launcher named after an agent takes its binary from that agent's file" {
    mkdir -p "$BATS_TEST_TMPDIR/agents"
    printf 'AGENT_COMMAND=/usr/bin/env\n' > "$BATS_TEST_TMPDIR/agents/codex.env"
    ln -s "$SCRIPT" "$BATS_TEST_TMPDIR/codex-safe"
    run env -u AGENT_COMMAND AGENT_DIR="$BATS_TEST_TMPDIR/agents" \
        "$BATS_TEST_TMPDIR/codex-safe"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sg-called group=agent-sandbox"* ]]
    [[ "$output" == *"arg=[/usr/bin/env]"* ]]
}

@test "a named launcher still takes the group and the proxy from the machine" {
    mkdir -p "$BATS_TEST_TMPDIR/agents"
    printf 'AGENT_COMMAND=/usr/bin/true\n' > "$BATS_TEST_TMPDIR/agents/codex.env"
    cat > "$BATS_TEST_TMPDIR/agent-run.env" <<EOF
AGENT_GROUP=from-file
AGENT_ENV_FILE=$ENV_FILE
EOF
    # The -run suffix names an agent the same way -safe does.
    ln -s "$SCRIPT" "$BATS_TEST_TMPDIR/codex-run"
    run env -u AGENT_GROUP -u AGENT_COMMAND -u AGENT_ENV_FILE \
        AGENT_CONFIG="$BATS_TEST_TMPDIR/agent-run.env" \
        AGENT_DIR="$BATS_TEST_TMPDIR/agents" \
        AGENT_DEBUG_ENV=1 "$BATS_TEST_TMPDIR/codex-run"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sg-called group=from-file"* ]]
    [[ "$output" == *"HTTPS_PROXY=http://user:secret@127.0.0.1:8129"* ]]
}

@test "the agent's own file wins over the shared one" {
    mkdir -p "$BATS_TEST_TMPDIR/agents"
    printf 'AGENT_COMMAND=/usr/bin/env\n' > "$BATS_TEST_TMPDIR/agents/codex.env"
    cat > "$BATS_TEST_TMPDIR/agent-run.env" <<EOF
AGENT_GROUP=agent-sandbox
AGENT_COMMAND=/usr/bin/true
AGENT_ENV_FILE=$ENV_FILE
EOF
    ln -s "$SCRIPT" "$BATS_TEST_TMPDIR/codex-safe"
    run env -u AGENT_GROUP -u AGENT_COMMAND -u AGENT_ENV_FILE \
        AGENT_CONFIG="$BATS_TEST_TMPDIR/agent-run.env" \
        AGENT_DIR="$BATS_TEST_TMPDIR/agents" "$BATS_TEST_TMPDIR/codex-safe"
    [ "$status" -eq 0 ]
    [[ "$output" == *"arg=[/usr/bin/env]"* ]]
    [[ "$output" != *"arg=[/usr/bin/true]"* ]]
}

@test "a launcher whose agent has no file says which name is missing" {
    ln -s "$SCRIPT" "$BATS_TEST_TMPDIR/qwen-safe"
    run env AGENT_DIR="$BATS_TEST_TMPDIR/agents" "$BATS_TEST_TMPDIR/qwen-safe"
    [ "$status" -ne 0 ]
    [[ "$output" == *"qwen-safe:"* ]]
    [[ "$output" == *"no agent named 'qwen'"* ]]
    [[ "$output" != *"sg-called"* ]]
}

@test "an agent binary that is absent stops the launcher, with the reason" {
    # Otherwise sg reports "command not found", exits 127, and the tmux session
    # started for it closes in the same instant — a button that does nothing.
    run env AGENT_COMMAND="$BATS_TEST_TMPDIR/no-such-agent" "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not an executable file"* ]]
    [[ "$output" != *"sg-called"* ]]
}

@test "an agent named without a path must be in PATH" {
    run env AGENT_COMMAND=no-such-agent-in-path "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not in PATH"* ]]
}

@test "nothing but the agent's output reaches a pipe" {
    # The terminal reset belongs to a terminal: written to a pipe its escapes
    # become part of the output, and whatever parses that reads them as data.
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" != *$'\e'* ]]
}

@test "a named launcher ignores the AGENT_COMMAND it inherited" {
    # Every session an agent opens carries the AGENT_COMMAND that started it.
    # A launcher called by name inside such a session must start the agent its
    # name asks for, not the one that opened the session.
    mkdir -p "$BATS_TEST_TMPDIR/agents"
    printf 'AGENT_COMMAND=/usr/bin/env\n' > "$BATS_TEST_TMPDIR/agents/codex.env"
    ln -s "$SCRIPT" "$BATS_TEST_TMPDIR/codex-safe"
    run env AGENT_COMMAND=/usr/bin/true AGENT_DIR="$BATS_TEST_TMPDIR/agents" \
        "$BATS_TEST_TMPDIR/codex-safe"
    [ "$status" -eq 0 ]
    [[ "$output" == *"arg=[/usr/bin/env]"* ]]
    [[ "$output" != *"arg=[/usr/bin/true]"* ]]
}

@test "an agent file that names the launcher itself is refused" {
    mkdir -p "$BATS_TEST_TMPDIR/agents"
    ln -s "$SCRIPT" "$BATS_TEST_TMPDIR/codex-safe"
    printf 'AGENT_COMMAND=%s\n' "$BATS_TEST_TMPDIR/codex-safe" \
        > "$BATS_TEST_TMPDIR/agents/codex.env"
    run env -u AGENT_COMMAND AGENT_DIR="$BATS_TEST_TMPDIR/agents" \
        "$BATS_TEST_TMPDIR/codex-safe"
    [ "$status" -ne 0 ]
    [[ "$output" == *"names this launcher"* ]]
    [[ "$output" != *"sg-called"* ]]
}

@test "a launcher given itself as the agent is refused, by name or by path" {
    # make custom CMD='agent-run …' set AGENT_COMMAND=agent-run and the
    # launcher re-ran itself until the machine noticed (~18,700 processes).
    ln -s "$SCRIPT" "$STUB_DIR/agent-run"
    for cmd in agent-run "$STUB_DIR/agent-run" "$SCRIPT"; do
        run env AGENT_COMMAND="$cmd" "$SCRIPT" --model opus
        [ "$status" -ne 0 ]
        [[ "$output" == *"is this launcher"* ]]
        [[ "$output" != *"sg-called"* ]]
    done
}

@test "a named launcher given as the agent hands over to that launcher" {
    # pockterm's custom button runs `make custom CMD='gemini-safe'`, which
    # becomes AGENT_COMMAND=gemini-safe agent-run. gemini-safe is this script
    # under an agent's name and resets AGENT_COMMAND itself, so there is no
    # loop to refuse — the refusal above made every such button die at once.
    mkdir -p "$BATS_TEST_TMPDIR/agents"
    printf 'AGENT_COMMAND=/usr/bin/env\n' > "$BATS_TEST_TMPDIR/agents/codex.env"
    ln -s "$SCRIPT" "$STUB_DIR/codex-safe"
    for cmd in codex-safe "$STUB_DIR/codex-safe"; do
        run env AGENT_COMMAND="$cmd" AGENT_DIR="$BATS_TEST_TMPDIR/agents" \
            "$SCRIPT" -a never
        [ "$status" -eq 0 ]
        [[ "$output" == *"sg-called group=agent-sandbox"* ]]
        [[ "$output" == *"arg=[/usr/bin/env]"* ]]
        [[ "$output" == *"arg=[-a]"* ]]
        [[ "$output" == *"arg=[never]"* ]]
    done
}
