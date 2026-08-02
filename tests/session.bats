#!/usr/bin/env bats
#
# roost-session creates and finds the tmux sessions agents live in. The tests
# stub tmux: what matters here is which commands get issued, not that tmux
# does its job.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../ansible/roles/agent_sessions/files/roost-session"
    STUB_DIR="$BATS_TEST_TMPDIR/stub"
    mkdir -p "$STUB_DIR"
    # Records every invocation; pretends no session exists unless the test
    # says otherwise.
    cat > "$STUB_DIR/tmux" <<'EOF'
#!/usr/bin/env bash
echo "tmux $*" >> "$TMUX_LOG"
case "$1" in
    has-session) [ -n "${TMUX_SESSION_EXISTS:-}" ] && exit 0 || exit 1 ;;
    list-sessions) printf '%s\n' ${TMUX_SESSIONS:-} ;;
esac
exit 0
EOF
    chmod +x "$STUB_DIR/tmux"
    PATH="$STUB_DIR:$PATH"
    export PATH
    export TMUX_LOG="$BATS_TEST_TMPDIR/tmux.log"
    : > "$TMUX_LOG"
    export ROOST_PROJECT_DIR="$BATS_TEST_TMPDIR/projects"
    export ROOST_AGENT=/usr/local/bin/agent-run
    mkdir -p "$ROOST_PROJECT_DIR/demo"
}

@test "start creates a detached session named after the project" {
    run "$SCRIPT" start demo
    [ "$status" -eq 0 ]
    grep -q "tmux new-session -d -s roost-demo" "$TMUX_LOG"
}

@test "start runs the agent inside the session, in the project directory" {
    run "$SCRIPT" start demo
    grep -q -- "-c $ROOST_PROJECT_DIR/demo" "$TMUX_LOG"
    grep -q "agent-run" "$TMUX_LOG"
}

@test "start on an existing session does not create a second one" {
    TMUX_SESSION_EXISTS=1 run "$SCRIPT" start demo
    [ "$status" -eq 0 ]
    ! grep -q "new-session" "$TMUX_LOG"
}

@test "an unknown project is refused rather than created" {
    run "$SCRIPT" start nosuch
    [ "$status" -ne 0 ]
    [[ "$output" == *"nosuch"* ]]
    ! grep -q "new-session" "$TMUX_LOG"
}

@test "attach refuses when the session is not there" {
    run "$SCRIPT" attach demo
    [ "$status" -ne 0 ]
}

@test "list shows roost sessions" {
    TMUX_SESSIONS="roost-demo roost-other" run "$SCRIPT" list
    [ "$status" -eq 0 ]
    [[ "$output" == *"roost-demo"* ]]
}

@test "the session name is prefixed, so other tmux sessions are untouched" {
    run "$SCRIPT" start demo
    grep -q "roost-demo" "$TMUX_LOG"
    ! grep -qE "new-session -d -s demo\b" "$TMUX_LOG"
}

@test "no project name is an error, not a guess" {
    run "$SCRIPT" start
    [ "$status" -ne 0 ]
}
