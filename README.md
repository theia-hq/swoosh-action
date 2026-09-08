# swoosh-action

A GitHub Action that turns a CI runner into a node you reach by its public key: across GitHub's NAT, with
no port-forward, no SSH keys to manage, and nothing session-identifying in the logs.

Behind the runner's gate you serve whatever you name: a keyless shell, HTTP fetch, link diagnostics. ssh
is the headline (`swoosh ssh me/<label>` into the runner), but it is one service of several, and you
choose the set. Only your own devices and delegates can reach any of them.

**The name.** The runner becomes a node you drive with [`swoosh`](https://github.com/theia-hq/swoosh):
one command to reach it by key and use the services it serves.

## The idea
You `mint` the runner's identity on your laptop: one command that both derives the runner's identity
*before the runner exists* and records the name you'll reach it by. The runner adopts that authkey from a
secret: it becomes the derived device **and** trusts your signet. Then it serves its services over the
overlay behind the default family gate. You reach each by membership from your laptop.

The headline service is a **keyless shell** (an SSH server with no keys of its own). There is no ssh
password or authorized key behind it. What opens a session is **membership**: the runner trusts your
signet, so its family gate admits your devices, and your key self-signs a short-lived badge when you dial.
That capability is the authentication. This is why the repo can stay public: the authkey is a secret, gh
redacts node ids, and only a member of your signet can reach any service. (Unlike tmate / "print a URL",
nothing is read back from a log.)

## One-time setup (on your laptop)
```sh
swoosh mint ci-runner        # → prints an authkey, and records the contact me/ci-runner
```
A minted badge lasts 90 days unless you pass `--expires`. For a long-lived runner mint long:
`swoosh mint ci-runner --expires 365d`. See
[`swoosh mint`](https://github.com/theia-hq/swoosh/blob/main/docs/reference/commands.md#mint).
That's it: `mint` derives the runner's identity and saves how to reach it (`me/ci-runner`) in one step.
In the repo settings:
- **Secret** `THEIA_AUTHKEY` = the authkey `mint` printed (it carries the runner's device seed).

## Use it
```yaml
- uses: theia-hq/swoosh-action@v2
  with:
    authkey: ${{ secrets.THEIA_AUTHKEY }}
```
Trigger the workflow, then from your laptop reach whatever it serves:
```sh
swoosh ssh me/ci-runner                                # a shell in the runner
swoosh ping me/ci-runner                               # round-trip time
swoosh speed me/ci-runner                              # throughput
```
You're on the runner across GitHub's NAT, by a name you chose before it booted, and you never touched an
ssh key.

## Inputs

| input | required | default | what it is |
| ----- | -------- | ------- | ---------- |
| `authkey` | yes | — | the authkey `swoosh mint` printed. The runner adopts it to become that device and trust your signet. A secret. |
| `services` | no | `ssh=sshd: ping=ping: speed=speed:` | the services to serve (below). |
| `minutes` | no | — | hold the job open this many minutes for interactive use. Omit to run non-blocking (below). |
| `version` | no | `latest` | the swoosh release to install: `latest` or a pinned tag (e.g. `v2`). |

### `services`
Space-separated `name=addr` pairs. The default serves a full node: a keyless shell (`ssh=sshd:`) plus
`ping=ping:`/`speed=speed:` link diagnostics. Every entry must be `name=addr`: a bare `ping` or `ping:` is
refused. Name your own set to add or drop services:

```yaml
services: ssh=sshd: news=fetch:https://news.example web=127.0.0.1:8080
```

- `news=fetch:<origin>` (HTTP egress you can `swoosh fetch --via me/<label> <url>` through, fetched by the runner, streamed back).
- `inbox=recv:<dir>` (receive files pushed to the runner; `inbox=recv:` writes to `.`).
- `web=127.0.0.1:8080` (forward a local port on the runner).
- `sock=unix:/path` (forward a unix socket).

Every service is served behind the same family gate: only devices and delegates of the signet the runner
adopted can reach any of them. (See `swoosh serve` for the full addr grammar.)

### `minutes`
- **Omitted (non-blocking):** the node serves in the background, the workflow advances to your next
  steps, and the node stays reachable until the job ends.
- **`minutes: N`:** hold the job open for N minutes so you can ssh in, do your thing, then it stops.

End a held session early from your laptop with `swoosh stop --at me/<label>`, which reaches the runner's gated
control service and tears it down.

## Rotate
The runner's identity is disposable: `swoosh mint` a fresh authkey per use or per repo. Because the
authkey carries only a *derived* device seed (not your signet), a leaked one compromises that one runner,
never your root key, and you can revoke it.

## How it stays safe
- **Gated by membership.** Every service is served behind the family gate: only devices and delegates of
  the signet the runner adopted may reach it. The keyless shell (`sshd:`) has no auth of its own, so
  swoosh refuses to serve it with `--public` at all.
- **Log-safety by design.** The runner serves with `--quiet`, so the NodeId is never printed; it can't
  leak into a public log via a stray `cat`, not just a redirect.
- **Liveness check.** The hold verifies a served service is alive and fails fast if it died, instead of a
  blind `sleep`.
- **Checksum + provenance install.** The `swoosh` binary is downloaded from its GitHub Releases, checked
  against the published `.sha256`, and its build-provenance attestation verified, never a bare `curl | sudo`.

## Still to do
- **Cold Newcomer pass.** A stranger drops it in and gets a shell, with no prior context.
