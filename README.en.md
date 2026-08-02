# roost

[Русская версия](README.md)

A personal stand for CLI coding agents. A machine you already own — a
single-board computer, a mini PC, an old laptop, a VPS — becomes a server
where agents (Claude Code and any other CLI) live in tmux sessions. Their
outbound traffic is confined to a group with a predictable exit, and you reach
them from your phone through a web terminal.

> **Status: design.** The design lives in `docs/superpowers/specs/`; there is
> no code yet. Do not install.

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
