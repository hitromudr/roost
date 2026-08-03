#!/usr/bin/env bats
#
# The projects role, run for real against throwaway directories. Container
# tests cover the roles that touch the system; this one needs nothing but a
# writable directory, so it runs wherever ansible does — and the cases it
# covers are the ones that only appear on a machine with a history: a name
# already taken by something that is not a checkout, a checkout with work in
# it.
#
# Skipped where ansible is absent (CI installs ansible-lint, not ansible).

setup() {
    command -v ansible-playbook >/dev/null || skip "ansible is not installed"
    command -v git >/dev/null || skip "git is not installed"

    ROLES="$BATS_TEST_DIRNAME/../ansible/roles"
    WORK="$BATS_TEST_TMPDIR/work"
    mkdir -p "$WORK"

    # The repository the role clones from: local, so the tests need no network.
    ORIGIN="$BATS_TEST_TMPDIR/origin"
    git init -q --bare "$ORIGIN"
    seed="$BATS_TEST_TMPDIR/seed"
    git init -q "$seed"
    printf 'hello\n' > "$seed/file.txt"
    git -C "$seed" -c user.email=t@e -c user.name=t add -A
    git -C "$seed" -c user.email=t@e -c user.name=t commit -qm init
    git -C "$seed" branch -M main
    git -C "$seed" push -q "$ORIGIN" main
    # A bare repository initialised here defaults its HEAD to master; without
    # this, cloning it checks out nothing and the failure looks like the role's.
    git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main

    printf 'localhost ansible_connection=local\n' > "$BATS_TEST_TMPDIR/inventory"

    # No become: the role only needs root to install git, and git is here.
    cat > "$BATS_TEST_TMPDIR/play.yml" <<'EOF'
---
- name: Deploy projects
  hosts: localhost
  gather_facts: true
  roles:
    - projects
EOF
}

# run_role <json list of projects>
run_role() {
    ANSIBLE_ROLES_PATH="$ROLES" ANSIBLE_LOCALHOST_WARNING=False \
    ANSIBLE_INVENTORY_UNPARSED_WARNING=False \
        ansible-playbook -i "$BATS_TEST_TMPDIR/inventory" \
        "$BATS_TEST_TMPDIR/play.yml" \
        -e "projects_user=$(id -un)" \
        -e "projects_dir=$WORK" \
        -e "{\"projects_list\": $1}"
}

@test "a missing project is cloned" {
    run run_role "[{\"name\":\"alpha\",\"repo\":\"$ORIGIN\",\"version\":\"HEAD\"}]"
    [ "$status" -eq 0 ]
    [ -f "$WORK/alpha/file.txt" ]
}

@test "a directory that is not a repository is named and left alone" {
    mkdir -p "$WORK/deployed"
    printf 'artefact\n' > "$WORK/deployed/app.conf"

    run run_role "[{\"name\":\"deployed\",\"repo\":\"$ORIGIN\",\"version\":\"HEAD\"}]"

    [ "$status" -eq 0 ]
    [[ "$output" == *"not a git checkout"* ]]
    [[ "$output" == *"deployed"* ]]
    # The artefact is still there and no checkout was forced on top of it.
    [ "$(cat "$WORK/deployed/app.conf")" = "artefact" ]
    [ ! -e "$WORK/deployed/.git" ]
    [ ! -e "$WORK/deployed/file.txt" ]
}

@test "one occupied name does not stop the rest of the list" {
    mkdir -p "$WORK/deployed"
    printf 'artefact\n' > "$WORK/deployed/app.conf"

    run run_role "[{\"name\":\"deployed\",\"repo\":\"$ORIGIN\",\"version\":\"HEAD\"},
                   {\"name\":\"beta\",\"repo\":\"$ORIGIN\",\"version\":\"HEAD\"}]"

    [ "$status" -eq 0 ]
    [ -f "$WORK/beta/file.txt" ]
}

@test "a checkout with uncommitted work is named and not updated" {
    git clone -q "$ORIGIN" "$WORK/gamma"
    printf 'local edit\n' >> "$WORK/gamma/file.txt"

    run run_role "[{\"name\":\"gamma\",\"repo\":\"$ORIGIN\",\"version\":\"HEAD\"}]"

    [ "$status" -eq 0 ]
    [[ "$output" == *"uncommitted change"* ]]
    [ "$(tail -1 "$WORK/gamma/file.txt")" = "local edit" ]
}

@test "a project without its secrets is named only when it ships an example" {
    git clone -q "$ORIGIN" "$WORK/delta"
    printf 'TOKEN=\n' > "$WORK/delta/.env.example"

    run run_role "[{\"name\":\"delta\",\"repo\":\"$ORIGIN\",\"version\":\"HEAD\"}]"

    [ "$status" -eq 0 ]
    [[ "$output" == *"no .env here"* ]]
}

@test "a project with no example is not nagged about secrets" {
    git clone -q "$ORIGIN" "$WORK/epsilon"

    run run_role "[{\"name\":\"epsilon\",\"repo\":\"$ORIGIN\",\"version\":\"HEAD\"}]"

    [ "$status" -eq 0 ]
    [[ "$output" != *"no .env here"* ]]
}
