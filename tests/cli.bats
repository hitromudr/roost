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

@test "uninstall says what goes and what stays before doing anything" {
    write_conf "" "" mtls
    run "$ROOST" uninstall --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"egress rules"* ]]
    [[ "$output" == *"keeps"* ]]
    [[ "$output" == *"projects"* ]]
    # A dry run must not touch the machine.
    ! grep -q "ansible-playbook" "$STUB_LOG"
}

@test "uninstall without --purge keeps the group and the token" {
    write_conf "" "" mtls
    run "$ROOST" uninstall --dry-run
    [[ "$output" == *"sandbox group"* ]]
    [[ "$output" == *"--purge"* ]]
}

@test "uninstall --yes proceeds without asking" {
    write_conf "" "" mtls
    run "$ROOST" uninstall --yes
    [ "$status" -eq 0 ]
    grep -q "teardown.yml" "$STUB_LOG"
}

@test "uninstall --purge passes the flag through" {
    write_conf "" "" mtls
    run "$ROOST" uninstall --yes --purge
    grep -q "roost_purge=true" "$STUB_LOG"
}

@test "an unknown uninstall option is refused" {
    write_conf "" "" mtls
    run "$ROOST" uninstall --wipe-everything
    [ "$status" -ne 0 ]
}

@test "gate remove runs the teardown playbook" {
    write_conf gate.example cc.example mtls
    run "$ROOST" gate remove admin@gate.example
    [ "$status" -eq 0 ]
    grep -q "gate-teardown.yml" "$STUB_LOG"
}

@test "mtls install asks pockterm not to generate a token" {
    # A token the gate does not know about answers 401 to every link without
    # it, which looks exactly like a machine with no sessions.
    write_conf gate.example cc.example mtls
    run "$ROOST" install
    [ "$status" -eq 0 ]
    grep -q "publish_token=false" "$STUB_LOG"
}

@test "token auth keeps the token" {
    write_conf gate.example cc.example token
    run "$ROOST" install
    grep -q "publish_token=true" "$STUB_LOG"
}

@test "a public stand with no gate keeps the token" {
    # Nothing in front means the token is the only lock there is.
    write_conf "" "" mtls
    run "$ROOST" install
    grep -q "publish_token=true" "$STUB_LOG"
}

# --- project list -------------------------------------------------------

write_projects() {
    printf '%s\n' \
        '# name  repository  [branch]' \
        'isearch  https://git.example/isearch.git' \
        'sorter   https://github.com/x/sorter.git  develop' \
        > "$BATS_TEST_TMPDIR/projects.conf"
    export ROOST_PROJECTS="$BATS_TEST_TMPDIR/projects.conf"
}

@test "the project list is parsed into name, repo and branch" {
    write_conf "" "" mtls
    write_projects
    run "$ROOST" projects --list
    [ "$status" -eq 0 ]
    [[ "$output" == *'"name":"isearch"'* ]]
    [[ "$output" == *'"repo":"https://git.example/isearch.git"'* ]]
    [[ "$output" == *'"version":"develop"'* ]]
}

@test "a project without a branch tracks the repository head" {
    write_conf "" "" mtls
    write_projects
    run "$ROOST" projects --list
    [[ "$output" == *'"name":"isearch","repo":"https://git.example/isearch.git","version":"HEAD"'* ]]
}

@test "comments and blank lines are ignored" {
    write_conf "" "" mtls
    write_projects
    run "$ROOST" projects --list
    [ "$(grep -o '"name"' <<< "$output" | wc -l)" -eq 2 ]
}

@test "a malformed line is refused, naming the line" {
    write_conf "" "" mtls
    printf 'brokenline\n' > "$BATS_TEST_TMPDIR/projects.conf"
    export ROOST_PROJECTS="$BATS_TEST_TMPDIR/projects.conf"
    run "$ROOST" projects --list
    [ "$status" -ne 0 ]
    [[ "$output" == *"brokenline"* ]]
}

@test "no project list is not an error, just nothing to do" {
    write_conf "" "" mtls
    export ROOST_PROJECTS="$BATS_TEST_TMPDIR/absent.conf"
    run "$ROOST" projects
    [ "$status" -eq 0 ]
    [[ "$output" == *"no projects"* ]]
    ! grep -q "projects.yml" "$STUB_LOG"
}

@test "projects runs the playbook with the parsed list" {
    write_conf "" "" mtls
    write_projects
    run "$ROOST" projects
    [ "$status" -eq 0 ]
    grep -q "projects.yml" "$STUB_LOG"
    grep -q "isearch" "$STUB_LOG"
}

@test "the list reaches ansible as json, not as a string" {
    # Passed as key=value it arrives as a string, and `| length` then counts
    # characters — the summary claimed 91 projects for one.
    write_conf "" "" mtls
    write_projects
    run "$ROOST" projects
    grep -q '{"projects_list":' "$STUB_LOG"
}

@test "the user list reaches ansible as json, not as a string" {
    # As key=value it arrives as a string and `| first` returns "[", which
    # ansible then tries to look up as a user account.
    write_conf "" "" mtls
    run "$ROOST" install
    grep -q '{"egress_sandbox_users":' "$STUB_LOG"
}

@test "doctor calls out a sandbox with no way out" {
    write_conf "" "" mtls
    export ROOST_PROXY_ENV="$BATS_TEST_TMPDIR/proxy.env"
    printf '# PROXY_URL=http://user:pass@host:port\n' > "$ROOST_PROXY_ENV"
    STUB_RC=1 run "$ROOST" doctor
    # A commented-out example is not a proxy.
    [[ "$output" == *"no network at all"* ]]
    [[ "$output" == *"PROXY_URL="* ]]
}

@test "doctor is satisfied when the proxy is configured" {
    write_conf "" "" mtls
    export ROOST_PROXY_ENV="$BATS_TEST_TMPDIR/proxy.env"
    printf 'PROXY_URL=http://user:pass@127.0.0.1:8129\n' > "$ROOST_PROXY_ENV"
    STUB_RC=1 run "$ROOST" doctor
    [[ "$output" == *"has a proxy"* ]]
}

@test "the direct profile is not nagged about a proxy" {
    printf 'egress_profile=direct\nauth=mtls\n' > "$ROOST_CONF"
    export ROOST_PROXY_ENV="$BATS_TEST_TMPDIR/absent.env"
    STUB_RC=1 run "$ROOST" doctor
    # Unrestricted egress was the choice; there is nothing to proxy through.
    [[ "$output" != *"no network at all"* ]]
}
