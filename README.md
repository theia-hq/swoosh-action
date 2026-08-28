# swoosh-ssh

A GitHub Action that makes a CI runner reachable by `ssh` over the theia overlay: by its public key,
across GitHub's NAT, with no port-forward, no SSH keys to manage, and nothing session-identifying in
the logs.

## The idea
You pre-mint the runner's identity on your laptop, so you know how to address it *before the runner
exists*. The runner adopts that identity from a secret and exposes a **keyless shell** over the overlay —
an SSH server with no keys of its own. You `swoosh ssh` into it.

There is no ssh password or authorized key behind the shell. Instead, the one thing that can *open a
session* to it is the NodeId you name in `allow` — your laptop's key. That capability is the
authentication. This is why the repo can stay public: the runner key is a secret, the NodeId was never a
secret to you, gh redacts the rest, and no one but your key can reach the shell in the first place.
(Unlike tmate / "print a URL", nothing is read back from a log.)

## One-time setup (on your laptop)
```sh
swoosh identity --key ci-runner.key      # → bf01…  the runner's NodeId
swoosh contact add ci-runner bf01…       # you now know how to reach it, in advance
swoosh identity                          # → your laptop's own NodeId (the one key allowed to connect)
base64 ci-runner.key                     # copy this blob
```
In the repo settings:
- **Secret** `THEIA_CI_KEY` = the base64 blob above (the runner's identity).
- **Variable** `LAPTOP_ID` = your laptop's NodeId (from `swoosh identity`).

## Use it
```yaml
- uses: theia-hq/swoosh-action@v1
  with:
    key: ${{ secrets.THEIA_CI_KEY }}
    allow: ${{ vars.LAPTOP_ID }}
    minutes: 20
```
Trigger the workflow (`gh workflow run debug-ssh.yml`), then from your laptop:
```sh
swoosh ssh ci-runner
```
You're shelled into the runner, across GitHub's NAT, by a name you chose before it booted — and you
never touched an ssh key.

## Rotate
The runner's identity is disposable: mint a fresh `ci-runner.key` per use or per repo. The final form
(theia HD identity, P10) will let you *derive* it from your user key by label, so you hand a scoped token
instead of a raw secret.

## How it stays safe
- **Keyless, but gated** — the shell (`sshd:`) has no auth of its own, so `allow` is required: only your
  laptop NodeId may open a session. tightbeam refuses to expose `sshd:` publicly for this reason.
- **Log-safety by design** — `tightbeam expose --quiet`, so the NodeId is never printed; it can't leak
  into a public log via a stray `cat`, not just a redirect.
- **Liveness + early release** — the hold checks the shell is alive (fails fast if it died) and watches
  for `touch $RUNNER_TEMP/theia-release` to end early, instead of a blind `sleep`.
- **Checksum-verified install** — the `swoosh`/`tightbeam` binaries are downloaded from their GitHub
  Releases and checked against the published `.sha256`, never a bare `curl | sudo`.

## Still to do
- **Signed release binaries** — the install verifies a checksum, but the binaries are not yet signed.
- **Cold Newcomer pass** — a stranger drops it in and gets a shell, with no prior context.
