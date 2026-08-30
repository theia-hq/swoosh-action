# swoosh-ssh

A GitHub Action that makes a CI runner reachable by `ssh` over the theia overlay: by its public key,
across GitHub's NAT, with no port-forward, no SSH keys to manage, and nothing session-identifying in
the logs.

## The idea
You `mint` the runner's identity on your laptop — one command that both derives the runner's identity
*before the runner exists* and records the name you'll reach it by. The runner adopts that authkey from a
secret: it becomes the derived device **and** trusts your signet. Then it exposes a **keyless shell** over
the overlay — an SSH server with no keys of its own — behind the default family gate. You `swoosh ssh`
into it by membership.

There is no ssh password or authorized key behind the shell. What opens a session is **membership**: the
runner trusts your signet, so its family gate admits your devices, and your key self-signs a short-lived
badge when you dial. That capability is the authentication. This is why the repo can stay public: the
authkey is a secret, gh redacts node ids, and only a member of your signet can reach the shell.
(Unlike tmate / "print a URL", nothing is read back from a log.)

## One-time setup (on your laptop)
```sh
swoosh mint ci-runner        # → prints an authkey, and records the contact me/ci-runner
```
That's it — `mint` derives the runner's identity and saves how to reach it (`me/ci-runner`) in one step.
In the repo settings:
- **Secret** `THEIA_AUTHKEY` = the authkey `mint` printed (it carries the runner's device seed).

## Use it
```yaml
- uses: theia-hq/swoosh-action@v2
  with:
    authkey: ${{ secrets.THEIA_AUTHKEY }}
    minutes: 20
```
Trigger the workflow (`gh workflow run debug-ssh.yml`), then from your laptop:
```sh
swoosh ssh me/ci-runner
```
You're shelled into the runner, across GitHub's NAT, by a name you chose before it booted — and you
never touched an ssh key.

## Rotate
The runner's identity is disposable: `swoosh mint` a fresh authkey per use or per repo. Because the
authkey carries only a *derived* device seed (not your signet), a leaked one compromises that one runner,
never your root key — and you can revoke it.

## How it stays safe
- **Keyless, but gated by membership** — the shell (`sshd:`) has no auth of its own, so it is exposed
  behind the family gate: only devices and delegates of the signet the runner adopted may open a session.
  tightbeam refuses to expose `sshd:` with `--public` for exactly this reason.
- **Log-safety by design** — `tightbeam expose --quiet`, so the NodeId is never printed; it can't leak
  into a public log via a stray `cat`, not just a redirect.
- **Liveness + early release** — the hold checks the shell is alive (fails fast if it died) and watches
  for `touch $RUNNER_TEMP/theia-release` to end early, instead of a blind `sleep`.
- **Checksum-verified install** — the `swoosh`/`tightbeam` binaries are downloaded from their GitHub
  Releases and checked against the published `.sha256`, never a bare `curl | sudo`.

## Still to do
- **Signed release binaries** — the install verifies a checksum, but the binaries are not yet signed.
- **Authkey off argv** — `swoosh adopt` takes the authkey as an argument, so it is briefly visible in the
  runner's process list; a stdin/file form would remove even that (fine on a single-tenant runner today).
- **Cold Newcomer pass** — a stranger drops it in and gets a shell, with no prior context.
