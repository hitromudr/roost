# roost

[Русская версия](README.md)

A personal stand for CLI coding agents. A machine you already own — a
single-board computer, a mini PC, an old laptop, a VPS — becomes a server
where agents (Claude Code and any other CLI) live in tmux sessions. Their
outbound traffic is confined to a group with a predictable exit, and you reach
them from your phone through a web terminal.

> **Status: work in progress.** Every part is written — traffic confinement,
> publishing, sessions, environment sync, the `roost` wrapper and teardown.
> They are verified in containers and by dry runs; a complete stand, from a
> clean machine to a phone, has not been built end to end yet.

## Quick start

```bash
git clone https://github.com/<owner>/roost && cd roost
./roost setup      # a few questions; answers go to roost.conf
./roost install    # apply to this machine
./roost doctor     # check the stand is what it claims to be
```

If the stand is behind NAT, you also need a machine with a routable address:

```bash
./roost gate add user@vps.example   # nginx, TLS, client certificates
./roost qr                          # QR with the link for your phone
```

## What the roles do

| Role | Where | What |
|---|---|---|
| `egress_sandbox` | stand | the group, `gid-owner` rules, the agent launcher |
| `agent_sessions` | stand | tmux sessions per project, mouse mode for phones |
| `publish` | stand | the web terminal via its own installer, reverse tunnel |
| `gate` | public entry | nginx with TLS, client CA, the tunnel account |

Run playbooks from the repository root — `ansible.cfg` there points at
`ansible/roles`. Run `make deps` before the first time.

## Why

Working with an agent ties you to the machine it runs on. Close the laptop and
the work stops. Moving the agent to a machine that stays on is easy enough,
but three problems surface that everyone then solves from scratch:

- **Reaching the internet.** The agent needs its API. If the server changes
  networks or sits behind NAT, its external address drifts. roost confines the
  agent's traffic to a group allowed to talk to a local proxy and nothing
  else, so the exit stays the same wherever the machine is.
- **Reaching the server.** A machine at home has no public address. roost
  opens a reverse tunnel to any host that has one and puts TLS with
  authentication in front of it.
- **The environment.** An agent is useful in proportion to how well it knows
  your setup: config, keys, project context. roost carries these between your
  workstation and the stand, keeping secrets encrypted.

## Architecture

| Node | What it is | Required |
|---|---|---|
| `stand` | the machine agents run on, usually behind NAT | yes |
| `gate` | public entry point | no, if the stand is public |
| `workstation` | the machine you work from | yes |

Your phone talks to `gate` over TLS; `gate` forwards through the tunnel to the
web terminal on `stand`; behind the terminal is tmux with the agent. The agent
itself reaches the internet only through a local proxy — direct egress is
rejected for its group by firewall rules.

## Security model

Read this before installing: **the web terminal hands a full shell to whoever
reaches it.** Treat the stand like SSH access. Exposing it without TLS and
authentication is not acceptable, and the installer will refuse to do it.

The agent sandbox here is about predictable outbound traffic, not about
containing malicious code: the agent runs as your user and can do to your
files exactly what you can.

## Development

```bash
make help     # list targets
make check    # lint and tests
```

## Removing it

```bash
./roost uninstall --dry-run   # show what goes and what stays
./roost uninstall             # asks for confirmation
./roost uninstall --purge     # plus the group, the token and roost.conf
./roost gate remove user@vps.example
```

What goes: the rules and their unit, the launcher, the session helper, the
tunnel, the web terminal with its unit and checkout, and `/etc/roost`. What
stays: your projects and any running sessions — removing those should be a
decision, not a default. `--purge` additionally removes the sandbox group,
`/etc/pockterm` with its token, and `roost.conf` itself.

On the gate, `gate remove` takes out the vhost and the tunnel account but
keeps the client CA: deleting it invalidates the certificates already
installed on your devices. `--purge` removes that too. The domain's TLS
certificate is never touched.

Verified in a container: after teardown no rules remain in either address
family, and the machine is back to how it started.
