# roost — design

Date: 2026-08-02.

## The problem

Working with a CLI agent ties you to the machine it runs on. Moving it to a
machine that stays on is easy; making that setup pleasant is not. Three things
have to be solved, and today everyone solves them from scratch:

1. **Predictable egress.** The agent needs its provider's API. A machine that
   changes networks, or sits behind NAT, has a drifting external address.
2. **Reaching the machine.** No public address at home, and exposing a shell
   to the internet is not something to improvise.
3. **The environment.** An agent is useful in proportion to how well it knows
   your setup: shell config, keys, project context, its own memory.

roost packages one working answer to all three, as an installer rather than a
guide, because "it works by tonight" is verifiable and a guide is not.

## Nodes

| Node | What it is | Required |
|---|---|---|
| `stand` | the machine agents run on, usually behind NAT | yes |
| `gate` | public entry point with a routable address | no, if the stand is public |
| `workstation` | the machine you work from | yes |

The degenerate case — a public stand with no gate — is supported by skipping
the tunnel and pointing the TLS front at the stand itself.

## Roles

### `egress_sandbox`

The core, and the part worth publishing even if nothing else is.

A dedicated group per egress profile; firewall rules match on `gid-owner`;
the agent is launched into its group by a wrapper. Three profiles:

| Profile | Rule | For |
|---|---|---|
| `pinned` | loopback only; everything else REJECT. Agent reaches the net through a local proxy that is itself outside the sandbox | a fixed exit address that does not depend on where the machine is |
| `proxied` | a named list of allowed destinations plus the proxy | agents that also need, say, a package registry directly |
| `direct` | no restriction | trusted tasks; present so the profile is an explicit choice, not an omission |

`agent-run` is the launcher: reads proxy credentials from a 600 file, exports
the proxy environment, executes the agent under `sg <group>`, restores the
terminal afterwards. The agent command is configuration — Claude Code by
default, anything else by changing one line.

**Known limits, to be stated in the README:** `gid-owner` does not apply to
traffic originating inside containers or other network namespaces; the
sandbox constrains where traffic goes, not what the agent does to your files.

### `agent_sessions`

tmux sessions per project: naming convention, creation helper, restart after
reboot. Sessions are plain tmux — anything that speaks to tmux (including the
web terminal) works with them, and nothing is hidden behind a daemon.

### `publish`

Reverse tunnel from stand to gate, TLS and authentication on the gate, the web
terminal ([pockterm](https://github.com/hitromudr/pockterm)) on the stand.

Two authentication levels: a shared token to get started, mutual TLS for a
setup you keep. The installer refuses to publish without one of them.

### `env_sync`

A skeleton for a personal environment repository — shell and editor config,
`sops`+`age` for secrets, agent settings and machine-independent memory — plus
the commands that lay it out on both machines. The git host is a parameter:
GitHub, a self-hosted Forgejo, anything reachable.

One manual step remains by design: the private `age` key is moved between
machines by hand. Automating it would mean protecting the key with a secret
that lives on the same machine, which protects nothing.

## Deployment must be short

The measure of this project is how far someone gets in one evening, so the
paths are designed backwards from that.

**Server, from nothing:**

```bash
git clone https://github.com/<owner>/roost && cd roost
./roost install
```

The first run is a wizard: egress profile, proxy endpoint, gate address,
authentication level. Answers land in `roost.conf`; every later run is
idempotent and silent. Everything derivable is derived — architecture,
distribution, whether the machine has a public address — and everything
generatable is generated: tokens, tunnel keys, the client CA and certificates
for mutual TLS, systemd units.

**Gate, without leaving the stand:**

```bash
./roost gate add user@vps.example
```

Installs the tunnel endpoint and the TLS front over ssh. No second checkout,
no copying files by hand.

**Workstation:**

```bash
./roost client
```

Lays out the environment, and writes an ssh alias for the stand that picks its
own route: the local address when you are on the same network, the tunnel when
you are not. The alias is the same name in both cases.

**Phone:**

```bash
./roost client qr
```

Prints a QR code in the terminal — scan it and the PWA opens, already
carrying its credential. For mutual TLS the same command produces a one-time
link for the client certificate, since a `.p12` does not fit in a QR code.

**Verification is a command, not a checklist:**

```bash
./roost doctor
```

Checks what the README claims: direct egress from the sandbox group is
rejected, traffic through the proxy exits from the expected address, the
tunnel is up, the web terminal answers through the gate, sessions survive a
reboot. Failures print the fix, not just the symptom.

## Security model

The web terminal hands a full shell to whoever reaches it. This is the first
paragraph of the README, not a footnote. The stand is SSH-equivalent: TLS and
authentication are mandatory, and the installer will not publish without them.

No secrets in the repository, ever — including in history. Proxy credentials
and tokens are files with 600 permissions on the target machine, rendered from
templates. The repository ships examples with obviously fake values.

Wording matters: this is a tool for a **stable, predictable exit address**.
It is not a tool for evading geographic restrictions, and nothing in the
documentation should read as if it were.

## Testing

Roles run against a clean container or VM, and the claims above are the test
cases: a process in the sandbox group gets REJECT on direct egress; the same
process through the proxy exits from the expected address; the web terminal
answers through the gate; a session survives a reboot. `roost doctor` runs the
same checks on a live machine, so the test suite and the field diagnostic do
not drift apart.

Shell is linted with shellcheck, roles with ansible-lint, behaviour with bats.

## Scope of v1

In: one stand, one gate, Claude Code as the default agent, the four roles
above, the deployment paths above.

Out, deliberately: multi-user setups, a web dashboard, orchestration between
several agents, containerised agents. Each is a reasonable next step and none
is needed to make the first evening work.

## What this is built from

The pieces exist and are in production on the author's machines; roost
generalises them:

| Source | What is taken |
|---|---|
| `claude-safe` + `po-sandbox-firewall` | the group/`gid-owner` sandbox and the launcher, with credentials moved out of the script body |
| `pockterm` | the web terminal, as an external dependency |
| a personal dotfiles repo | the `sops`+`age` scheme and the split between shared and machine-local agent context |
| ansible roles for the tunnel and vhost | `publish`, rewritten without hardcoded hosts |

## Order of work

`egress_sandbox` → `publish` → `agent_sessions` → `env_sync`.

The first role is the most valuable and the most portable: if the project goes
no further, it is still useful on its own.
