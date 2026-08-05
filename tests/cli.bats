#!/usr/bin/env bats
#
# The roost wrapper is what a user actually types. These tests cover the
# parts that do not need a machine: reading and writing the config, refusing
# a configuration that cannot work, and what doctor concludes from a given
# state. Applying roles is covered by the role and container tests.

setup() {
    ROOST="$BATS_TEST_DIRNAME/../roost"
    export ROOST_CONF="$BATS_TEST_TMPDIR/roost.conf"
    STUB_DIR="$BATS_TEST_TMPDIR/stub"
    mkdir -p "$STUB_DIR"
    for tool in ansible-playbook systemctl tmux; do
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
egress_profile=${1-pinned}
agent_command=/usr/local/bin/claude
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
    write_conf
    run "$ROOST" install
    [ "$status" -eq 0 ]
    grep -q "ansible-playbook" "$STUB_LOG"
    grep -q "egress_sandbox_profile=pinned" "$STUB_LOG"
}

@test "an unknown egress profile is refused" {
    write_conf sieve
    run "$ROOST" install
    [ "$status" -ne 0 ]
    [[ "$output" == *"sieve"* ]]
    ! grep -q "ansible-playbook" "$STUB_LOG"
}

@test "uninstall promises nothing about what roost did not install" {
    # The sandbox is roost's; the web terminal, the tunnel and the shell on
    # this machine belong to whoever put them there. They may be named in the
    # "keeps" half — that is the point — but never in what goes.
    write_conf
    run "$ROOST" uninstall --dry-run
    local removed
    removed="$(sed -n '1,/It keeps:/p' <<< "$output")"
    [[ "$removed" != *"web terminal"* ]]
    [[ "$removed" != *"tunnel"* ]]
    [[ "$removed" == *"egress rules"* ]]
}

@test "doctor reports on a machine where nothing is installed" {
    write_conf
    STUB_RC=1 run "$ROOST" doctor
    # Nothing installed is a finding, not a crash.
    [ "$status" -ne 0 ]
    [[ "$output" == *"egress"* ]]
}

@test "doctor names the fix, not just the symptom" {
    write_conf
    STUB_RC=1 run "$ROOST" doctor
    [[ "$output" == *"roost install"* ]]
}

@test "uninstall says what goes and what stays before doing anything" {
    write_conf
    run "$ROOST" uninstall --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"egress rules"* ]]
    [[ "$output" == *"keeps"* ]]
    [[ "$output" == *"projects"* ]]
    # A dry run must not touch the machine.
    ! grep -q "ansible-playbook" "$STUB_LOG"
}

@test "uninstall without --purge keeps the group" {
    write_conf
    run "$ROOST" uninstall --dry-run
    [[ "$output" == *"sandbox group"* ]]
    [[ "$output" == *"--purge"* ]]
}

@test "uninstall --yes proceeds without asking" {
    write_conf
    run "$ROOST" uninstall --yes
    [ "$status" -eq 0 ]
    grep -q "teardown.yml" "$STUB_LOG"
}

@test "uninstall --purge passes the flag through" {
    write_conf
    run "$ROOST" uninstall --yes --purge
    grep -q "roost_purge=true" "$STUB_LOG"
}

@test "an unknown uninstall option is refused" {
    write_conf
    run "$ROOST" uninstall --wipe-everything
    [ "$status" -ne 0 ]
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
    write_conf
    write_projects
    run "$ROOST" projects --list
    [ "$status" -eq 0 ]
    [[ "$output" == *'"name":"isearch"'* ]]
    [[ "$output" == *'"repo":"https://git.example/isearch.git"'* ]]
    [[ "$output" == *'"version":"develop"'* ]]
}

@test "a project without a branch tracks the repository head" {
    write_conf
    write_projects
    run "$ROOST" projects --list
    [[ "$output" == *'"name":"isearch","repo":"https://git.example/isearch.git","version":"HEAD"'* ]]
}

@test "comments and blank lines are ignored" {
    write_conf
    write_projects
    run "$ROOST" projects --list
    [ "$(grep -o '"name"' <<< "$output" | wc -l)" -eq 2 ]
}

@test "a malformed line is refused, naming the line" {
    write_conf
    printf 'brokenline\n' > "$BATS_TEST_TMPDIR/projects.conf"
    export ROOST_PROJECTS="$BATS_TEST_TMPDIR/projects.conf"
    run "$ROOST" projects --list
    [ "$status" -ne 0 ]
    [[ "$output" == *"brokenline"* ]]
}

@test "no project list is not an error, just nothing to do" {
    write_conf
    export ROOST_PROJECTS="$BATS_TEST_TMPDIR/absent.conf"
    run "$ROOST" projects
    [ "$status" -eq 0 ]
    [[ "$output" == *"no projects"* ]]
    ! grep -q "projects.yml" "$STUB_LOG"
}

@test "projects works on a machine that has no stand config" {
    # The same list is applied on a machine that runs no agents and has no
    # roost.conf to read.
    write_projects
    run "$ROOST" projects
    [ "$status" -eq 0 ]
    grep -q "projects.yml" "$STUB_LOG"
    grep -q "projects_dir=$HOME/work" "$STUB_LOG"
}

@test "projects runs the playbook with the parsed list" {
    write_conf
    write_projects
    run "$ROOST" projects
    [ "$status" -eq 0 ]
    grep -q "projects.yml" "$STUB_LOG"
    grep -q "isearch" "$STUB_LOG"
}

@test "the list reaches ansible as json, not as a string" {
    # Passed as key=value it arrives as a string, and `| length` then counts
    # characters — the summary claimed 91 projects for one.
    write_conf
    write_projects
    run "$ROOST" projects
    grep -q '{"projects_list":' "$STUB_LOG"
}

@test "the user list reaches ansible as json, not as a string" {
    # As key=value it arrives as a string and `| first` returns "[", which
    # ansible then tries to look up as a user account.
    write_conf
    run "$ROOST" install
    grep -q '{"egress_sandbox_users":' "$STUB_LOG"
}

@test "doctor calls out a sandbox with no way out" {
    write_conf
    export ROOST_PROXY_ENV="$BATS_TEST_TMPDIR/proxy.env"
    printf '# PROXY_URL=http://user:pass@host:port\n' > "$ROOST_PROXY_ENV"
    STUB_RC=1 run "$ROOST" doctor
    # A commented-out example is not a proxy.
    [[ "$output" == *"no network at all"* ]]
    [[ "$output" == *"PROXY_URL="* ]]
}

@test "doctor is satisfied when the proxy is configured" {
    write_conf
    export ROOST_PROXY_ENV="$BATS_TEST_TMPDIR/proxy.env"
    printf 'PROXY_URL=http://user:pass@127.0.0.1:8129\n' > "$ROOST_PROXY_ENV"
    STUB_RC=1 run "$ROOST" doctor
    [[ "$output" == *"has a proxy"* ]]
}

@test "doctor calls out a credentials file the launcher cannot read" {
    # Readable by anyone means the proxy password is readable by anyone; the
    # other half of this — owned by root — is what killed sessions on the Pi.
    write_conf
    export ROOST_PROXY_ENV="$BATS_TEST_TMPDIR/proxy.env"
    printf 'PROXY_URL=http://user:pass@127.0.0.1:8129\n' > "$ROOST_PROXY_ENV"
    chmod 644 "$ROOST_PROXY_ENV"
    STUB_RC=1 run "$ROOST" doctor
    [[ "$output" == *"permissions 644"* ]]
    [[ "$output" == *"chmod 640"* ]]
}

@test "the direct profile is not nagged about a proxy" {
    write_conf direct
    export ROOST_PROXY_ENV="$BATS_TEST_TMPDIR/absent.env"
    STUB_RC=1 run "$ROOST" doctor
    # Unrestricted egress was the choice; there is nothing to proxy through.
    [[ "$output" != *"no network at all"* ]]
}

# --- extra agents -------------------------------------------------------

@test "install passes the extra agents to ansible" {
    write_conf
    printf 'agents=codex:/home/you/.local/bin/codex\n' >> "$ROOST_CONF"
    run "$ROOST" install
    [ "$status" -eq 0 ]
    grep -q '"egress_sandbox_agents": {"codex":"/home/you/.local/bin/codex"}' "$STUB_LOG"
}

@test "two extra agents are both passed" {
    write_conf
    printf 'agents=codex:/opt/codex,qwen:/opt/qwen\n' >> "$ROOST_CONF"
    run "$ROOST" install
    [ "$status" -eq 0 ]
    grep -q '"codex":"/opt/codex","qwen":"/opt/qwen"' "$STUB_LOG"
}

@test "an agent without a command is refused before anything is applied" {
    write_conf
    printf 'agents=codex\n' >> "$ROOST_CONF"
    run "$ROOST" install
    [ "$status" -ne 0 ]
    [[ "$output" == *"no command"* ]]
    # A name that would become a file name and a launcher name must not reach
    # ansible half-formed.
    ! grep -q "ansible-playbook" "$STUB_LOG"
}

@test "an agent name that would not make a usable launcher is refused" {
    write_conf
    printf 'agents=../etc/codex:/opt/codex\n' >> "$ROOST_CONF"
    run "$ROOST" install
    [ "$status" -ne 0 ]
    [[ "$output" == *"usable agent name"* ]]
}

@test "doctor names an extra agent whose launcher is not installed" {
    write_conf
    printf 'agents=frobnicate:/usr/bin/true\n' >> "$ROOST_CONF"
    run "$ROOST" doctor
    [ "$status" -ne 0 ]
    [[ "$output" == *"frobnicate"* ]]
    [[ "$output" == *"roost install"* ]]
}

# --- the one command, and the pieces it is made of -----------------------
# These cover what the wrapper decides on its own: which command starts a
# session, what is asked before something is published, and what is refused
# for want of a step before it. Applying the roles is the roles' own tests.

@test "help mentions the one command" {
    run "$ROOST" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"roost up"* ]]
}

@test "the agent roost installed is what the launcher is pointed at" {
    cat > "$ROOST_CONF" <<CONF
egress_profile=direct
agent_command=
CONF
    export ROOST_AGENT_STATE="$BATS_TEST_TMPDIR/agent.env"
    printf 'AGENT_INSTALLED_COMMAND=/opt/agents/claude\n' > "$ROOST_AGENT_STATE"
    run "$ROOST" install
    [ "$status" -eq 0 ]
    grep -q "egress_sandbox_agent_command=/opt/agents/claude" "$STUB_LOG"
}

@test "a command named in the config outranks what was installed" {
    write_conf
    export ROOST_AGENT_STATE="$BATS_TEST_TMPDIR/agent.env"
    printf 'AGENT_INSTALLED_COMMAND=/opt/agents/claude\n' > "$ROOST_AGENT_STATE"
    run "$ROOST" install
    [ "$status" -eq 0 ]
    grep -q "egress_sandbox_agent_command=/usr/local/bin/claude" "$STUB_LOG"
}

@test "the path an installer chose is written back into the config" {
    cat > "$ROOST_CONF" <<CONF
egress_profile=direct
agent_command=
CONF
    export ROOST_AGENT_STATE="$BATS_TEST_TMPDIR/agent.env"
    printf 'AGENT_INSTALLED_COMMAND=/home/x/.local/bin/claude\n' > "$ROOST_AGENT_STATE"
    run "$ROOST" agent
    [ "$status" -eq 0 ]
    grep -q "^agent_command=/home/x/.local/bin/claude$" "$ROOST_CONF"
}

@test "the agent step is asked for by tag, not by running everything" {
    write_conf
    run "$ROOST" agent
    [ "$status" -eq 0 ]
    grep -q -- "--tags agent" "$STUB_LOG"
}

@test "install does not run the terminal or the way in" {
    write_conf
    run "$ROOST" install
    [ "$status" -eq 0 ]
    grep -q -- "--tags egress,sessions,env" "$STUB_LOG"
    ! grep -q -- "--tags terminal" "$STUB_LOG"
}

@test "a stand that wants no terminal is not given one" {
    write_conf
    printf 'terminal=false\n' >> "$ROOST_CONF"
    run "$ROOST" terminal
    [ "$status" -eq 0 ]
    ! grep -q "ansible-playbook" "$STUB_LOG"
}

@test "publishing is not done without being asked" {
    write_conf
    run "$ROOST" expose < /dev/null
    [ "$status" -ne 0 ]
    [[ "$output" == *"full shell"* ]]
    ! grep -q "ansible-playbook" "$STUB_LOG"
}

@test "publishing with --yes says which port and which upstream" {
    write_conf
    printf 'listen=127.0.0.1:8130\ntls_port=9443\n' >> "$ROOST_CONF"
    run "$ROOST" expose --yes
    [ "$status" -eq 0 ]
    grep -q "expose_tls_port=9443" "$STUB_LOG"
    grep -q "expose_upstream=127.0.0.1:8130" "$STUB_LOG"
}

@test "a host given on the command line wins over the config" {
    write_conf
    printf 'public_host=from.conf\n' >> "$ROOST_CONF"
    run "$ROOST" expose --yes --host from.flag
    [ "$status" -eq 0 ]
    grep -q "expose_host=from.flag" "$STUB_LOG"
}

@test "printing what to add asks nobody and changes nothing" {
    write_conf
    run "$ROOST" expose --print < /dev/null
    [ "$status" -eq 0 ]
    grep -q "expose_front=print" "$STUB_LOG"
}

@test "an unknown expose option is refused" {
    write_conf
    run "$ROOST" expose --sideways
    [ "$status" -ne 0 ]
    [[ "$output" == *"--sideways"* ]]
}

@test "a QR code before anything is published says what is missing" {
    write_conf
    export ROOST_EXPOSE_STATE="$BATS_TEST_TMPDIR/expose.env"
    run "$ROOST" qr
    [ "$status" -ne 0 ]
    [[ "$output" == *"roost expose"* ]]
}

@test "a QR code without a terminal names the step that installs one" {
    write_conf
    export ROOST_EXPOSE_STATE="$BATS_TEST_TMPDIR/expose.env"
    # Named rather than absent from PATH: this suite also runs on a stand,
    # where pockterm is installed and "not installed" cannot be arranged by
    # leaving it out.
    export ROOST_POCKTERM_BIN=pockterm-that-is-not-here
    printf 'EXPOSE_URL=https://example:8443\n' > "$ROOST_EXPOSE_STATE"
    run "$ROOST" qr
    [ "$status" -ne 0 ]
    [[ "$output" == *"roost terminal"* ]]
}

@test "doctor says which binary a session would start" {
    cat > "$ROOST_CONF" <<CONF
egress_profile=direct
agent_command=$BATS_TEST_TMPDIR/claude
CONF
    printf '#!/bin/sh\n' > "$BATS_TEST_TMPDIR/claude"
    chmod +x "$BATS_TEST_TMPDIR/claude"
    run "$ROOST" doctor
    [[ "$output" == *"the agent is $BATS_TEST_TMPDIR/claude"* ]]
}

@test "doctor calls out an agent that is not there" {
    cat > "$ROOST_CONF" <<CONF
egress_profile=direct
agent_command=$BATS_TEST_TMPDIR/absent
CONF
    run "$ROOST" doctor
    [ "$status" -ne 0 ]
    [[ "$output" == *"not an executable file"* ]]
    [[ "$output" == *"roost agent"* ]]
}

@test "doctor calls out a terminal whose buttons bypass the sandbox" {
    cat > "$ROOST_CONF" <<CONF
egress_profile=direct
agent_command=/usr/bin/true
CONF
    export ROOST_TERMINAL_STATE="$BATS_TEST_TMPDIR/terminal.env"
    export ROOST_TERMINAL_ENV="$BATS_TEST_TMPDIR/pockterm.env"
    printf 'TERMINAL_LISTEN=127.0.0.1:8130\n' > "$ROOST_TERMINAL_STATE"
    printf 'CLAUDE=claude\n' > "$ROOST_TERMINAL_ENV"
    run "$ROOST" doctor
    [ "$status" -ne 0 ]
    [[ "$output" == *"unsandboxed"* ]]
}

@test "doctor is satisfied when the buttons go through the launcher" {
    cat > "$ROOST_CONF" <<CONF
egress_profile=direct
agent_command=/usr/bin/true
CONF
    export ROOST_TERMINAL_STATE="$BATS_TEST_TMPDIR/terminal.env"
    export ROOST_TERMINAL_ENV="$BATS_TEST_TMPDIR/pockterm.env"
    printf 'TERMINAL_LISTEN=127.0.0.1:8130\n' > "$ROOST_TERMINAL_STATE"
    printf 'CLAUDE=/usr/local/bin/agent-run\n' > "$ROOST_TERMINAL_ENV"
    run "$ROOST" doctor
    [[ "$output" == *"go through the sandbox"* ]]
}
