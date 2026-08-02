# egress_sandbox

Confines an agent's outbound traffic to a group, so that where it can reach
is a property of the process rather than of the network it happens to be on.

Every rule matches `--gid-owner`, which means the policy is inherited by
whatever the agent spawns: a shell it opens, a package manager it calls, a
script it writes and runs.

## Profiles

| Profile | Effect | Use when |
|---|---|---|
| `pinned` | loopback only; everything else rejected | the agent should reach the internet solely through a local proxy, so its exit address never changes |
| `proxied` | loopback plus the destinations you list | the agent also needs something directly — a registry, an internal host |
| `direct` | nothing installed | you decided against restrictions; the group and launcher still exist |

`direct` exists so that an unrestricted agent is a decision somebody made,
not what happens when configuration is skipped.

## What it installs

- the group, and the accounts you list as members;
- `/usr/local/sbin/egress-firewall` — the policy, applied at boot by a
  oneshot unit ordered before the network comes up;
- `/usr/local/bin/agent-run` — the launcher: reads proxy credentials from a
  0600 file, exports them, executes the agent under `sg`, and restores the
  terminal afterwards;
- `/etc/roost/agent-run.env` — which group and which agent (no secrets);
- `/etc/roost/agent-proxy.env` — the credentials, 0600, seeded as a template
  you fill in unless you pass `egress_sandbox_proxy_url`.

## Variables

See `defaults/main.yml`. The ones you are likely to set:

```yaml
egress_sandbox_group: agent-sandbox
egress_sandbox_profile: pinned          # pinned | proxied | direct
egress_sandbox_allow: []                # for proxied: addresses or CIDRs
egress_sandbox_users: [you]
egress_sandbox_agent_command: /usr/local/bin/claude
egress_sandbox_proxy_url: ""            # better supplied from a vault
```

## Limits worth knowing before you rely on this

- `gid-owner` does not see traffic that originates inside a container or
  another network namespace. An agent that runs docker is outside the policy.
- This constrains **where traffic goes**, not what the agent does locally: it
  runs as your user and can touch every file you can.
- Group membership is evaluated at process start. A shell you opened before
  the role ran keeps its old groups until you log in again.

## Verifying

`tests/egress_firewall.bats` checks which rules a configuration produces.
`tests/integration/egress_container.sh` applies them in a container and
checks the outcome: a sandboxed process is rejected outbound, still reaches
loopback, processes outside the group are unaffected, re-applying adds no
duplicates, and `clear` restores everything.
