# A second agent — Codex alongside Claude Code

Date: 2026-08-04. Written on the stand (rpi5), to be continued on the laptop.

Status: **step 2 of the order of work is done** (2026-08-05, on the stand);
the rest is still design notes. Codex itself is installed and logged in — by
`dotfiles/install-codex.sh`, not by roost, which owns only what it installs.

What shipped, and where it differs from the sketch below: the agent is chosen
by **the name the launcher is invoked as** — `/usr/local/bin/codex-safe`, a
link to `agent-run`, reading `/etc/roost/agents/codex.env` — rather than by
`agent-run -a <name>`. The flag was the wrong shape: Codex has an `-a` of its
own (`-a never`, its approval policy), and a launcher that eats it would take
the flag the agent was meant to get. `-safe` also matches the wrapper names
both machines already carry for Claude, so the habit transfers.

One correction the first run produced: a named launcher must ignore an
inherited `AGENT_COMMAND`. Every session an agent opens carries the one that
started it, so `codex-safe` run inside a Claude session started Claude and
reported its version. The name outranks the environment — the only place where
it does.

Two of the three decisions at the end are settled (2026-08-05); the sticky exit
is the one still open.

## Why now

A corporate Codex subscription became available. The intent is not "try it
out" but the same standing as Claude Code: a participant in every project,
under the same process, in the same range of conditions — sandboxed egress,
tmux sessions, project context, the rules the repository already states.

That makes this a question about roost's shape, not about installing a binary.
roost's own claim is that the agent is configuration: `egress_sandbox` matches
policy on `gid-owner`, never on the binary, and the agent is one variable,
`AGENT_COMMAND`. A second agent is the first real test of that claim.

## What was measured, not assumed

Checked on the stand on 2026-08-04, from inside the sandbox group
(`gid=agent-sandbox`, `pinned` profile, proxy EMMET on `127.0.0.1:8129`):

| Check | Result |
|---|---|
| `codex` on the stand | absent; no `~/.codex` |
| `@openai/codex` in the registry | 0.146.0, `linux-arm64` artifact present, `engines: node>=16` |
| node on the stand | v20.19.2 — sufficient |
| `https://api.openai.com/v1/models` | 401 — reachable through the proxy |
| `https://chatgpt.com/backend-api/codex/responses` | 405 on GET — reachable |
| `https://auth.openai.com/.well-known/openid-configuration` | 200 via EMMET and via POLKA |
| `https://chatgpt.com/` (HTML) | 403 from both exits — Cloudflare on datacenter IPs |
| landlock in the kernel | **absent**: `/sys/kernel/security/lsm` = `capability` |

Two conclusions. Egress needs no work — the API endpoints answer through the
existing proxy. And the browser login flow is the part that does not fit: the
HTML entry point is 403 from the sanctioned exits, and the stand has no
browser anyway.

## Where it fits, and where it does not

It fits cheaply: Codex launched through `agent-run` inherits the group and the
proxy, and the firewall does not care what it is running.

Four things break, and all four are the same defect — the machinery assumes
one agent.

### 1. One `AGENT_COMMAND` per machine

`/etc/roost/agent-run.env` names exactly one agent. Named profiles instead:
`/etc/roost/agents/<name>.env` holding `AGENT_COMMAND`, `AGENT_ENV_FILE` and
`AGENT_PROFILE`, selected by `agent-run -a <name>` (a `<name>-run` symlink is
the convenience form). The default stays what it is today, so a stand that
knows one agent keeps working untouched.

One group, not two. The egress policy is identical for both — loopback plus
the proxy — so there is nothing to separate. A group per agent buys one thing:
each agent can only reach its own provider, which is visible in the rules and
survives a misconfigured proxy variable. It costs a second rule set and a
second membership to keep straight. Not now; revisit if the exits diverge.

### 2. Session names do not mention the agent

`roost-<project>` collides the moment two agents want the same project — and
on the `roost` project itself the name is already taken. Rename to
`roost-<agent>-<project>`.

The rename is the small half. The large half is that two agents in one
checkout are two writers in one tree, which is the failure this repository was
already taught once: two owners of one unit break it the first time they
disagree (see `CLAUDE.md`, "Scope"). The rule that already exists for machines
— parallel work goes in separate branches — extends to agents:

> **One checkout, one agent.** Concurrent work on the same project means a
> `git worktree` or separate branches in separate directories, never two
> sessions in the same directory.

`roost-session start` can enforce the useful part of this: refuse to start a
second agent's session in a directory that already has one, and say why.

**Settled 2026-08-05: the rule is stated, nothing enforces it yet.** The rule
went into `dotfiles/claude/projects/work/common.md`, where the process rules for
`~/work` live and from where both machines get them. Enforcement was declined
for now because the cheap half does not cover the common case: `roost-session`
would guard only the sessions it opens, while the sessions that actually collide
are started from a phone through `~/work/Makefile` — a file owned by another
repository's role. A guard in one of the two places would read as protection
that is not there.

One thing does *not* get enforcement for free either way: Codex reads
`AGENTS.md` and does not understand the `@`-import that pulls `common.md` in, so
until the split in section 3 exists the rule is visible to Claude and invisible
to Codex.

### 3. Codex does not read `CLAUDE.md`

It reads `AGENTS.md` walking up the directory tree, plus a global
`~/.codex/AGENTS.md`, and it does not understand `@`-imports. The process
rules currently live in three layers Codex would see none of:
`dotfiles/claude/projects/work/common.md` → `~/work/CLAUDE.md` →
`<project>/CLAUDE.md`.

Three options were considered:

| Option | Cost | Objection |
|---|---|---|
| thin `AGENTS.md` pointing at `CLAUDE.md` | minimal | depends on the agent choosing to follow the pointer |
| `AGENTS.md` as a symlink to `CLAUDE.md` | none | Codex is handed sections about memory, skills and `settings.json` it has no counterpart for |
| split: agent-independent rules in `AGENTS.md`, Claude-specific layered on top in `CLAUDE.md` | one-off editing pass per repository | none found |

The split is the choice. It is the same move the repositories already make
with `common.md` and an `@`-import — a continuation, not a new scheme. What
belongs in `AGENTS.md`: language, tone, reporting errors, destructive actions,
read-before-write, tests-first, the secrets rule, the project's own
conventions. What stays in `CLAUDE.md`: memory paths, skills, settings
layering, and the `@`-import of the shared part.

Because `@`-imports are not available to Codex, the machine-wide layer has to
be a real file at `~/.codex/AGENTS.md`. That means a Codex counterpart to
`dotfiles/claude/sync-projects.sh`, laying out `~/.codex/config.toml` and the
global `AGENTS.md` from `dotfiles`. Same registry idea, same reason: a project
with its own repository carries its own instructions; only the machine layer
is deployed.

### 4. Memory is one-sided

`~/.claude/projects/<path>/memory/` does not exist for Codex, and Codex has no
equivalent to hand back. So the rule this forces:

> **Agent memory is private; the state of the work lives in the repository.**

Partly true already (`exante/STATE.md`, `JOURNAL.md`,
`sax/docs/sessions/STATE.md`). Codex is the reason to finish it: otherwise two
agents hold different beliefs about one task and nothing outside them shows it.

## The sandbox Codex brings, and the one this kernel does not

Codex confines its own file writes with landlock plus seccomp. This kernel
(6.12.75-rpt-rpi-2712) has landlock off — the LSM list is `capability` alone.
So on this stand Codex runs with full filesystem access and roost's egress
policy is the only confinement in place. That is a change in what the sandbox
means, and it should be stated where the profile is documented rather than
discovered.

Turning landlock on is `lsm=landlock,capability` in
`/boot/firmware/cmdline.txt` — owned by the `RPi5` repository, and a reboot of
the stand. Worth doing, separately from this work.

## Work outside roost

The same change touches repositories this one does not own. Recorded here so
the list is not rebuilt later; each belongs in its own repository's history.

| Repository | Change |
|---|---|
| `dotfiles` | `~/.codex/config.toml` and global `~/.codex/AGENTS.md` layout; the `AGENTS.md`/`CLAUDE.md` split of `common.md`; README section |
| `devops` | a `make codex` target beside `make claude` — the session Makefile is owned by role `pockterm_app`, not by roost |
| `bricks` | the project template must ship `AGENTS.md`, or every new project starts blind to Codex |
| `RPi5` | landlock in `cmdline.txt`, with the reboot that implies |
| `~/work/CLAUDE.md` (stand) | the "who owns what" section gains a second agent |

## Operator decisions

1. **Authentication — settled 2026-08-05.** Not by copying `auth.json`: the
   refresh token is single-use, so a copy on two machines puts itself out at the
   first rotation. Each machine logs in for itself with `--device-auth`, no
   browser and no callback port; the device-code page is opened by the person's
   own browser, so its geography is theirs. What remains on the stand is a
   per-device corporate credential that can be revoked on its own — narrower
   than the laptop's token, but still a corporate credential on a machine
   `exante/CLAUDE.md` says corporate keys do not belong on. A deliberate
   exception, not an oversight.
2. **Where the corporate subscription applies — settled 2026-08-05: everywhere,
   including personal projects.** Codex on `natal`, `politicum` or `self` is the
   owner's call and is normal; no per-session weighing. What this does *not*
   loosen is the traffic in the other direction, which is what
   `exante/CLAUDE.md` is about: no corporate secrets, no corporate checkouts and
   no run artefacts on this machine.
3. **Sticky exit — settled 2026-08-05: the same exit, risk accepted.** Both
   agents leave through EMMET. A separate exit for OpenAI would mean a second
   sandbox group and a second rule set to keep in step, and the invariant that
   matters — one account, one address — is not broken by sharing one. Revisit if
   OpenAI asks for phone verification again or Anthropic objects to the address;
   until then a second exit is work without a cause. The risk that was accepted
   is named: one datacentre address in Switzerland carries both a personal and a
   corporate account, and it already showed once — the first Codex login
   demanded a phone precisely because of that address.

## Order of work

Installing the package is not first. An agent that arrives before the
`AGENTS.md` layer exists knows none of the process, and before the session
rule exists it can open as a second writer in an occupied checkout.

1. The `AGENTS.md` / `CLAUDE.md` split, and one-checkout-one-agent as a stated
   rule (`dotfiles`, then per project).
2. Named agent profiles in `egress_sandbox`, with bats coverage for both.
3. Session names carrying the agent, and the refusal in `roost-session`.
4. The package, the launcher entry, `make codex`, `roost doctor` checking the
   second channel.
5. README and README.en, both languages, as the repository requires.

## Also on the table: navigation

Raised in the same session and not a roost matter, kept here so it is not
lost. Fifteen directories under `~/work` are listed alphabetically in one
table written for an agent, in a file a person does not open; role is
invisible, so `bricks`, `dotfiles` and `infra-secrets` read as projects. Some
directories have four entry points (`devops`: README, CLAUDE.md, WARP.md,
CHANGELOG — and WARP.md belongs to a different tool).

Proposal: group by role — workplace (`dotfiles`, `infra-secrets`, `bricks`,
`roost`, `RPi5`, `devops`), products (`pockterm`, `natal`, `politicum`,
`hostery`, `guide`, `sax`), control and personal (`exante`, `self`) — and give
a person one entry point, `~/work/README.md`: three lines per directory (what
it is, which file to read first, who owns deployment), plus the rule that a
directory has exactly one entry file. That README is also where the paragraph
on which agent does what naturally goes.
