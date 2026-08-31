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
That's it: `mint` derives the runner's identity and saves how to reach it (`me/ci-runner`) in one step.
In the repo settings:
- **Secret** `THEIA_AUTHKEY` = the authkey `mint` printed (it carries the runner's device seed).

## Use it
```yaml
- uses: theia-hq/swoosh-action@v2
  with:
    authkey: ${{ secrets.THEIA_AUTHKEY }}
    services: ssh=sshd: fetch=fetch:   # default is ssh=sshd:; name any set you want served
    minutes: 20
```
Trigger the workflow (`gh workflow run debug-ssh.yml`), then from your laptop reach whatever it serves:
```sh
swoosh ssh me/ci-runner                       # a shell in the runner
swoosh fetch https://example.com --via me/ci-runner   # fetch from the runner's network
```
You're on the runner across GitHub's NAT, by a name you chose before it booted, and you never touched an
ssh key.

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
- **Liveness + early release.** The hold checks a served service is alive (fails fast if it died) and
  watches for `touch $RUNNER_TEMP/theia-release` to end early, instead of a blind `sleep`.
- **Checksum-verified install.** The `swoosh` binary is downloaded from its GitHub Releases and checked
  against the published `.sha256`, never a bare `curl | sudo`.

## Still to do
- **Signed release binaries.** The install verifies a checksum, but the binaries are not yet signed.
- **Authkey off argv.** `swoosh adopt` takes the authkey as an argument, so it is briefly visible in the
  runner's process list; a stdin/file form would remove even that (fine on a single-tenant runner today).
- **Cold Newcomer pass.** A stranger drops it in and gets a shell, with no prior context.
