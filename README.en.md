# roost

[Русская версия](README.md)

An installer for a machine that runs CLI coding agents. Whatever you have — a
single-board computer, a mini PC, an old laptop, a VPS — gets a sandbox with a
predictable way out to the internet, the agent itself, tmux sessions per project,
your own checkouts, and a web terminal to reach all of it from a phone.

## How it works

One chain, and everything else in this file is a part of it:

```
phone → front (TLS) → terminal on loopback → tmux session → agent-run → agent
```

- **The agent** lives in the `agent-sandbox` group. `gid-owner` rules allow that
  group loopback only — which means the local proxy, and the proxy is outside the
  sandbox. The exit becomes predictable and stops depending on where the machine
  currently is.
- **A session** is plain tmux, starting the agent through the `agent-run` wrapper.
  Plain enough that `ssh -t` or `mosh` work with it, not only the terminal below.
- **The terminal** is [pockterm](https://github.com/hitromudr/pockterm): a
  separate project, one Go binary with a mobile PWA inside it. It lists tmux
  sessions and attaches to the one you pick; it **does not create** sessions —
  a Makefile does, and roost points that Makefile at `agent-run`. It listens on
  loopback only.
- **The front** is TLS and a lock in front of the terminal: nginx on this machine
  if it has an address, or a gate if it has none.

Three words used as terms from here on:

| Word | Means |
|---|---|
| **stand** | the machine agents live on: sandbox, sessions, terminal |
| **gate** | a machine with a public address, through which a stand behind NAT is reachable |
| **session** | a tmux session per project, `roost-<project>`, with an agent in it |

## What the machine needs

- Linux with systemd and `sudo`; one of `apt`, `dnf`, `pacman`, `zypper` or
  `apk` — roost installs ansible itself.
- A free port for TLS (`8443` by default) and, if the terminal is installed,
  ~200MB for building it: the Go toolchain is downloaded into `/opt/roost`, and
  teardown removes it.
- A domain is **not** required: the name is derived from the machine's address
  through `sslip.io`.
- A public address is not required either: a machine behind NAT needs a gate —
  a second machine with an address and an sshd.

## Quick start

```bash
git clone https://github.com/hitromudr/roost && cd roost
./roost up
```

One command, in this order:

1. asks a few questions and writes the answers to `roost.conf`;
2. installs ansible, if it is missing;
3. installs the agent, if it is missing;
4. creates the sandbox group and the egress rules;
5. brings up the terminal on loopback and points its buttons at `agent-run`;
6. opens a way to it: a certificate and roost's own vhost — or a tunnel to a gate;
7. prints a QR code for your phone and runs `roost doctor`.

On the phone: scan the code, then "add to home screen" — the page behaves like an
app, in its own window without tabs. Logging the agent into its provider happens
from there: the session opens its ordinary login screen.

Every step is also a command of its own, because each touches something the
machine may already have an owner for. `roost install` still means exactly what it
always did — sandbox, sessions, environment — and installs no terminal.

## Reaching it from a phone

The terminal always listens on loopback. One of two things serves it outward.

### The machine has an address of its own

```bash
./roost expose      # roost's own vhost in nginx, a Let's Encrypt certificate
./roost qr          # the code with the address and the token
```

You may have no domain: the name is then derived from the machine's address
through `sslip.io` (`203-0-113-5.sslip.io`), and the certificate is still a real
one — which is what lets the page be installed as an app.

### Behind NAT: a gate

This needs a second machine with a routable address. `gate=` says which:

```bash
# gate=roost-tunnel@vps.example
./roost tunnel        # on the stand: roost's own key and a unit holding one forward
./roost gate          # prints what to add on the gate
./roost gate --apply  # or installs it over your own ssh access
```

Three files named after roost appear on the gate, and one line:

| What | Why |
|---|---|
| a line in `authorized_keys` | `restrict,port-forwarding,permitlisten="127.0.0.1:18130"` — one forward and nothing else: no shell, no agent, no second port |
| `/etc/ssh/sshd_config.d/roost-tunnel.conf` | without it a hardened sshd refuses the forward |
| `/etc/nginx/conf.d/roost-terminal.conf` | serves the terminal through the forward |

The certificate is issued **on the gate**: it has the address, so it is what can
prove the name. The tunnel's account is created by the gate's owner — `--apply`
does not do that.

### The lock: a token or a certificate

| | `token` (default) | `mtls` |
|---|---|---|
| what holds the door | a string in the URL your phone saved | a client certificate on the device |
| how many steps | one: scan the QR | two: install the certificate, then open the terminal |
| where the secret lives | browser history and the front's logs | the phone's own store, not readable out of it |
| changing it | `roost token` — every phone scans a new code | `roost enroll <device>`, one device at a time |
| a lost phone | rotate the token: the other devices reconnect too | `roost-ca revoke <device>` — the others are untouched |

Give a device its certificate:

```bash
./roost enroll phone
```

That prints a QR code with a **one-time link** to the device's bundle, and the
password its importer will ask for. The link lives ten minutes, used or not.

Take a lost device back out:

```bash
sudo roost-ca revoke phone && sudo systemctl reload nginx
```

The buttons in the session drawer — the ones that start a session from the phone —
start the agent **through `agent-run`**, which is to say inside the sandbox.
`roost doctor` checks exactly this: buttons that work while sandboxing nothing
look like success. How that join is made is in [Why it is like
this](#why-it-is-like-this).

## Commands

| Command | What it does |
|---|---|
| `roost up` | all of it in order: agent, sandbox, terminal, way in, QR |
| `roost setup` | questions; answers go to `roost.conf` |
| `roost install` | sandbox, sessions, environment |
| `roost agent` | installs the agent if it is missing; records the path it found |
| `roost terminal` | the terminal — only where there is none |
| `roost expose` | TLS in front of the terminal, on this machine |
| `roost tunnel` | a reverse tunnel to a gate, for a machine with no address |
| `roost gate [--apply]` | prints (or installs) what the gate needs |
| `roost enroll <device>` | issues a client certificate for one device |
| `roost qr` | the QR code with the address and the token |
| `roost token` | replaces the terminal's token and prints the new code |
| `roost projects [--list]` | brings this machine up to `projects.conf` |
| `roost doctor` | checks the stand is what it claims to be |
| `roost uninstall [--purge]` | removes what roost installed |

## Configuration

All of it in `roost.conf`; `roost setup` writes it from your answers, and
[`roost.conf.example`](roost.conf.example) explains every line. The file is
gitignored: it holds one machine's addresses and credentials.

| Key | Default | Meaning |
|---|---|---|
| `egress_profile` | `pinned` | `pinned` — loopback only, out through a local proxy; `proxied` — plus named destinations; `direct` — no restrictions |
| `proxy_url` | empty | the proxy the agent goes out through. Written to `/etc/roost/agent-proxy.env` (0640) |
| `expected_exit` | empty | the address the agent's traffic **should** leave from. `doctor` compares |
| `agent_command` | empty | the agent binary. Empty means roost installs Claude Code and records the path here |
| `agents` | empty | further agents, `name:command`, comma-separated |
| `project_dir` | `~/work` | where projects live; sessions are named after directories here |
| `env_repo` | empty | the environment repository: shell, editor and agent config |
| `env_branch` | `HEAD` | its branch; `HEAD` follows whatever the repository calls default |
| `terminal` | `true` | whether to install the terminal |
| `listen` | `127.0.0.1:8130` | the terminal's address. Loopback only |
| `gate` | empty | `user@host` of a machine with a public address, when this one has none |
| `public_host` | empty | the domain for your phone. Empty derives an `sslip.io` name from the machine's address |
| `tls_port` | `8443` | the TLS port. Not 443: on a machine that does anything, it already belongs to something |
| `client_auth` | `token` | the lock: `token` or `mtls` |
| `email` | empty | contact address for Let's Encrypt |

> **Check the exit address before you log an agent in.** A proxy that answers is
> not the same as a proxy that changes where you come from: a local `3proxy` on
> the same server sends the traffic out of that server's own address. A request
> from an address the provider does not expect is grounds for suspending the
> account. `roost doctor` prints the address it found and compares it with
> `expected_exit`; while that is empty it says there was nothing to compare
> against.

The `pinned` and `proxied` profiles with no `PROXY_URL` leave the agent with **no
network at all** — it fails on its first request, and `doctor` says so.

## Projects and environment

`projects.conf` names the repositories that belong on **every** machine you work
from:

```
isearch  https://git.example/isearch.git
sorter   https://github.com/x/sorter.git  develop
```

`./roost projects` brings the machine it runs on up to that list — equally at home
on the stand and on your laptop. Nothing already there is overwritten: a checkout
with uncommitted work is named and skipped, so is a name held by a directory with
no `.git` in it, and the rest of the list is still checked out.

The environment comes from `env_repo`: that repository is put in
`<project_dir>/dotfiles` and its own installer runs (`./install.sh`). If it
carries encrypted files (`*.sops.*`), the role insists the age key is present —
without it the secrets stay encrypted while the installer reports success.

## A second agent

```
agents=codex:/home/you/.local/bin/codex
```

`roost install` installs `/usr/local/bin/codex-safe` — a link to the same
`agent-run` — and `/etc/roost/agents/codex.env`, which names the binary and
nothing else. The group, the proxy and the profile stay the machine's: one policy
for every agent on it.

## Boundaries: what roost owns

**roost owns only what roost installed.** Four rules follow, and the code obeys
them:

1. **A terminal is installed only where there is none.** A `pockterm.service`
   without `/etc/roost/terminal.env` beside it is the mark of another owner, and
   the role stops and says what to do instead.
2. **roost owns files, not services.** One file is added to somebody else's
   nginx; `nginx -t` is asked before the reload, and the file is taken back out if
   it does not parse. The reload itself needs your say-so.
3. **What roost cannot own, it prints.** A front door there is no file to add to
   (Caddy over its admin API, somebody else's gate) gets a printed recipe.
4. **Everything added comes out by name.** Teardown reads the state files;
   pockterm is removed by its own uninstaller.

What actually appears on the machine:

| Part | Where |
|---|---|
| the rules and their unit | `/usr/local/sbin/egress-firewall`, unit `egress-firewall` |
| launchers: `agent-run`, `agent-exec`, `roost-session` | `/usr/local/bin` |
| the agent | `~/.local/bin/claude` by default |
| the terminal | unit `pockterm`, `/etc/pockterm`, sources and toolchain in `/opt/roost` |
| the front | `/etc/nginx/conf.d/roost-terminal.conf` — here, or on the gate when there is one |
| the authority (with `mtls`) | `/etc/roost/ca` (0700) |
| the tunnel (with `gate=`) | unit `roost-tunnel`, key in `/etc/roost/tunnel` |
| what roost installed | `/etc/roost/*.env` |

## Security model

The sandbox here is about predictable outbound traffic, not about containing
malicious code: the agent runs as your user and can do to your files exactly what
you can.

**A terminal hands a full shell to whoever reaches it.** Treat that address like
SSH. By default the door is held by a token behind TLS — enough to start; for a
permanent installation use client certificates (`client_auth=mtls`).

No secrets in the repository. Anything host-specific — proxy credentials,
addresses, the repository list — is configuration: `roost.conf`, `projects.conf`
and `ansible/inventory` are gitignored, and only their `.example` counterparts
travel.

## What is verified, and how

| Claim | By what |
|---|---|
| installation is idempotent; a second run changes nothing | a live VPS, three `roost up` runs |
| teardown returns the machine to how it started | a live VPS: no rules, no group, no units; the neighbours' nginx intact |
| the rules reject direct egress and leave nothing behind | container (`egress_container.sh`) |
| a session started from a phone runs the agent in the group | a live VPS: the process tree and `Groups:` |
| a certificate gets in; a foreign or revoked one does not | container (`mtls_container.sh`) |
| the forward holds; the key gets neither a shell nor a second forward | container (`tunnel_container.sh`) |
| a gate and a stand as two live machines | **not verified** |
| installing the PWA and importing a certificate on a phone | **not verified** |

## Development

```bash
make help              # list targets
make check             # lint and tests: shellcheck, ansible-lint, bats
make test-integration  # three suites in throwaway containers (needs docker)
```

The `projects` and `env_sync` roles are run for real against throwaway
directories — ansible is all they need. The roles use `ansible.builtin` only; run
playbooks from the repository root, where `ansible.cfg` is.

## Removing it

```bash
./roost uninstall --dry-run   # show what goes and what stays
./roost uninstall             # asks for confirmation
./roost uninstall --purge     # plus the sandbox group and roost.conf
```

| Goes | Stays |
|---|---|
| the rules and their unit, the launchers, the session helper, `/etc/roost` | your projects and any running sessions |
| the terminal (through its own uninstaller), the vhost file, the build toolchain | the agent binary, and whatever it is logged in as |
| the tunnel: its unit and its key | the certificate — it is still valid |
| the certificate authority and the enrolment directory | everything roost did not install |

For the gate's side, teardown prints what is left there: only its owner can
remove it.

## Why it is like this

The decisions that would otherwise look arbitrary.

**Why the terminal's buttons start the agent through a wrapper.** pockterm
declares `CLAUDE ?=` and `AGENT ?=` in its session Makefile, and `?=` yields to
the environment; the service's environment is its env file. roost owns two lines
there, the Makefile stays pockterm's, and no third copy of the policy appears. The
alternative — a Makefile of roost's own — would be a copy that drifts the first
time pockterm edits its one.

**Why roost never becomes a second owner.** An early version installed the
terminal itself, and on a machine that already had one it generated a second
token — one the reverse proxy in front knew nothing about. Every request answered
`401`, which a browser renders as a machine with no sessions, and an evening went
into finding out why. Two owners of one unit break it the first time they
disagree.

**Why the exit address is a check of its own.** The first stand set up from a
config file was pointed at a local proxy that answered — and came out of that same
machine's address. `pinned` there bought predictability but not separation, and no
test catches that.

**Why the certificate travels as a link rather than in the QR code.** A device's
bundle is 4.4KB and a QR code holds 2953 bytes, and a code that dense is not
something a phone reads off a screen. That is measured; `tests/ca.bats` fails if
it ever stops being true.

**Why the gate's half is printed.** roost has no state file there, does not know
what else that nginx serves, and must not be the thing that reloads it by
surprise.

**Why `install` did not grow into `up`.** Machines that already call `install`
must not acquire a terminal on their next update.

The full record of decisions is in
[`docs/superpowers/specs/`](docs/superpowers/specs/).
