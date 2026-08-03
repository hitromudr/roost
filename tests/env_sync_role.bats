#!/usr/bin/env bats
#
# The env_sync role against a throwaway environment repository. Same shape as
# projects_role.bats: no container, no root, skipped where ansible is absent.

setup() {
    command -v ansible-playbook >/dev/null || skip "ansible is not installed"
    command -v git >/dev/null || skip "git is not installed"

    ROLES="$BATS_TEST_DIRNAME/../ansible/roles"
    DEST="$BATS_TEST_TMPDIR/dotfiles"
    KEY="$BATS_TEST_TMPDIR/keys.txt"
    MARKER="$BATS_TEST_TMPDIR/installed"

    # An environment repository on `master`, which is what a repository that
    # predates the main-branch default actually has.
    ORIGIN="$BATS_TEST_TMPDIR/origin"
    git init -q "$ORIGIN" --initial-branch=master
    cat > "$ORIGIN/install.sh" <<EOF
#!/usr/bin/env bash
echo ran > "$MARKER"
EOF
    chmod +x "$ORIGIN/install.sh"
    git -C "$ORIGIN" -c user.email=t@e -c user.name=t add -A
    git -C "$ORIGIN" -c user.email=t@e -c user.name=t commit -qm init

    printf 'localhost ansible_connection=local\n' > "$BATS_TEST_TMPDIR/inventory"
    cat > "$BATS_TEST_TMPDIR/play.yml" <<'EOF'
---
- name: Sync the environment
  hosts: localhost
  gather_facts: true
  roles:
    - env_sync
EOF
}

# add_secret puts an encrypted-looking file in the environment repository.
add_secret() {
    printf 'enc\n' > "$ORIGIN/secrets.sops.env"
    git -C "$ORIGIN" -c user.email=t@e -c user.name=t add -A
    git -C "$ORIGIN" -c user.email=t@e -c user.name=t commit -qm secret
}

# run_role [extra -e arguments]
run_role() {
    ANSIBLE_ROLES_PATH="$ROLES" ANSIBLE_LOCALHOST_WARNING=False \
    ANSIBLE_INVENTORY_UNPARSED_WARNING=False \
        ansible-playbook -i "$BATS_TEST_TMPDIR/inventory" \
        "$BATS_TEST_TMPDIR/play.yml" \
        -e "env_sync_user=$(id -un)" \
        -e "env_sync_repo=$ORIGIN" \
        -e "env_sync_dir=$DEST" \
        -e "env_sync_age_key=$KEY" \
        "$@"
}

@test "an environment repository on master is checked out, not asked for main" {
    run run_role
    [ "$status" -eq 0 ]
    [ -f "$DEST/install.sh" ]
    [ -f "$MARKER" ]
}

@test "an explicit branch is still honoured" {
    git -C "$ORIGIN" branch -q other
    run run_role -e env_sync_version=other
    [ "$status" -eq 0 ]
    [ "$(git -C "$DEST" rev-parse --abbrev-ref HEAD)" = "other" ]
}

@test "encrypted files with no key stop the run" {
    add_secret
    run run_role
    [ "$status" -ne 0 ]
    [[ "$output" == *"$KEY"* ]]
    [ ! -f "$MARKER" ]
}

@test "encrypted files with a key present are fine" {
    add_secret
    printf 'AGE-SECRET-KEY-TEST\n' > "$KEY"
    run run_role
    [ "$status" -eq 0 ]
    [ -f "$MARKER" ]
    [ "$(stat -c '%a' "$KEY")" = "600" ]
}

@test "no encrypted files means no key is demanded" {
    run run_role
    [ "$status" -eq 0 ]
    [ -f "$MARKER" ]
}

@test "the check can be turned off for a repository that carries secrets" {
    add_secret
    run run_role -e env_sync_expect_age_key=false
    [ "$status" -eq 0 ]
    [ -f "$MARKER" ]
}

@test "the check can be demanded for a repository that carries none" {
    run run_role -e env_sync_expect_age_key=true
    [ "$status" -ne 0 ]
    [[ "$output" == *"$KEY"* ]]
}
