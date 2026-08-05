#!/usr/bin/env bats
#
# agent-exec is the launcher for a caller that hands over a whole command line
# — the web terminal's custom buttons. What has to be true is that the command
# asked for is the command that runs, and that it runs through the same policy
# as everything else; the mistake it exists to prevent is `agent-run qwen`,
# which starts the configured agent and gives it "qwen" as an argument.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../ansible/roles/egress_sandbox/files/agent-exec"
    STUB_DIR="$BATS_TEST_TMPDIR/stub"
    mkdir -p "$STUB_DIR"
    # Stands in for agent-run: reports the command it was told to start and
    # the arguments it was given.
    # A loop rather than one printf with "$@": printf repeats its format for
    # every argument and runs it once even with none, so `arg=[]` would appear
    # where the point of the test is that no argument was passed.
    cat > "$STUB_DIR/agent-run" <<'EOF'
#!/usr/bin/env bash
echo "command=$AGENT_COMMAND"
for a in "$@"; do printf 'arg=[%s]\n' "$a"; done
EOF
    chmod +x "$STUB_DIR/agent-run"
    export AGENT_RUN="$STUB_DIR/agent-run"
}

@test "the first word becomes the agent, the rest its arguments" {
    run "$SCRIPT" qwen --yolo
    [ "$status" -eq 0 ]
    [[ "$output" == *"command=qwen"* ]]
    [[ "$output" == *"arg=[--yolo]"* ]]
}

@test "a command on its own reaches the launcher with no arguments" {
    run "$SCRIPT" qwen
    [ "$status" -eq 0 ]
    [[ "$output" == *"command=qwen"* ]]
    [[ "$output" != *"arg=["* ]]
}

@test "an argument with spaces survives the trip" {
    run "$SCRIPT" qwen -p "two words"
    [ "$status" -eq 0 ]
    [[ "$output" == *"arg=[two words]"* ]]
}

@test "no command at all is an error, not a guess" {
    run "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"usage"* ]]
}

# A missing launcher is the failure that looks like nothing happening: the
# session opens and closes, and on a phone that reads as a button that does
# not work.
@test "a launcher that is not there is named" {
    AGENT_RUN="$BATS_TEST_TMPDIR/absent" run "$SCRIPT" qwen
    [ "$status" -ne 0 ]
    [[ "$output" == *"absent"* ]]
    [[ "$output" == *"roost install"* ]]
}
