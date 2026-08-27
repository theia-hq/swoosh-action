# swoosh-ssh (DRAFT — not published)

A GitHub Action that makes a CI runner reachable by `ssh` over the theia overlay: by its public key,
across GitHub's NAT, with no port-forward and nothing session-identifying in the logs.

## The idea
You pre-mint the runner's identity on your laptop, so you know how to address it *before the runner
exists*. The runner adopts that identity from a secret and exposes its sshd over the overlay. You
`swoosh ssh` into it. This is why the repo can stay public: the key is a secret, the NodeId was never a
secret to you, and gh redacts the rest. (Unlike tmate / "print a URL", nothing is read back from a log.)

## One-time setup (on your laptop)
```sh
swoosh identity --key ci-runner.key      # → bf01…  the runner's NodeId
swoosh contact add ci-runner bf01…       # you now know how to reach it, in advance
swoosh identity                          # → your laptop's own NodeId (for the strict gate)
base64 ci-runner.key                     # copy this blob
```
In the repo settings:
- **Secret** `THEIA_CI_KEY` = the base64 blob above (the runner's identity).
- **Variable** `SSH_PUBKEY` = your public ssh key (`cat ~/.ssh/id_ed25519.pub`).
- **Variable** `LAPTOP_ID` = your laptop's NodeId (from `swoosh identity`).

## Use it
```yaml
- uses: theia-hq/swoosh-action@v1
  with:
    key: ${{ secrets.THEIA_CI_KEY }}
    authorized-key: ${{ vars.SSH_PUBKEY }}
    allow: ${{ vars.LAPTOP_ID }}
    minutes: 20
```
Trigger the workflow (`gh workflow run debug-ssh.yml`), then from your laptop:
```sh
swoosh ssh ci-runner
```
You're shelled into the runner, across GitHub's NAT, by a name you chose before it booted.

## Rotate
The runner's identity is disposable: mint a fresh `ci-runner.key` per use or per repo. The final form
(theia HD identity, P10) will let you *derive* it from your user key by label, so you hand a scoped token
instead of a raw secret.

## Status (Skeptic YELLOW → blockers addressed in this draft)
Addressed here after the Skeptic vet (`notes/reviews/2026-08-27-skeptic-gha-demo.md`):
- **Strict gate by default** — `allow` (your laptop NodeId) is required unless you opt into `open: true`.
- **Log-safety by design** — `tightbeam expose --quiet`, so the NodeId is never printed; it can't leak
  into a public log via a stray `cat`, not just a redirect.
- **Liveness + early release** — the hold checks the tunnel is alive (fails fast if it died) and watches
  for `touch $RUNNER_TEMP/theia-release` to end early, instead of a blind `sleep`.
- **Checksum-verified install** (shape) — never a bare `curl | sudo`.

Still needed before ship (see `notes/design/gha-ssh-demo.md`):
- **Real signed release binaries** for `swoosh`/`tightbeam` — the install URLs are placeholders until we
  cut releases. Release workflows are drafted in each repo (`.github/workflows/release.yml`); they need a
  tag push to validate. This is the last real engineering task.
- **Publish** this as `theia-hq/swoosh-action` (founder's call — it goes public).
- **Cold Newcomer** pass (a stranger drops it in and gets a shell).
