# swoosh-action

A GitHub Action that turns a CI runner into a node you reach by its public key: across GitHub's NAT, with
no port-forward and no SSH keys to manage. Mint the runner's name on your laptop before the runner exists,
then dial `me/ci-runner` while the job runs.

## Quickstart

This workflow serves the default set (a keyless shell, `ping`, and `speed`) and holds the runner open for
30 minutes:

```yaml
name: swoosh
on:
  workflow_dispatch: {}
jobs:
  node:
    runs-on: ubuntu-latest
    steps:
      - uses: theia-hq/swoosh-action@v2
        with:
          authkey: ${{ secrets.THEIA_AUTHKEY }}
          minutes: 30
```

Save it as `.github/workflows/swoosh.yml`, push it to your default branch, then run it from the Actions
tab or with `gh workflow run swoosh.yml`.

`authkey` is required. The runner adopts it to become the device identity
[`swoosh mint`](https://github.com/theia-hq/swoosh/blob/main/docs/reference/commands/mint.md) derived and
to trust the root key that minted it (your signet), so its gate admits your devices and the delegates you
grant. The authkey carries a device seed: keep it in a repository secret, never in the workflow file.
[Prerequisites](#prerequisites) has the commands that produce it.

`services` is optional and defaults to `ssh=sshd: ping=ping: speed=speed:`.
[Serve more than a shell](#serve-more-than-a-shell) has the grammar, examples, and reference links.

`minutes` is optional and unset by default. Set it to hold the job open while you work on the runner.
[Hold the job open](#hold-the-job-open) covers what happens without it and how to end a hold early.

`version` is optional and defaults to `latest`, the newest swoosh release. Set a release tag such as
`v0.8.0` to pin it. [Choose the swoosh version](#choose-the-swoosh-version) covers the install check.

## Prerequisites

1. A laptop with the [`swoosh`](https://github.com/theia-hq/swoosh) client installed. Get a binary from
   the [releases](https://github.com/theia-hq/swoosh/releases) page. The client mints your signet (your
   root key) on first use, and
   [`swoosh identity`](https://github.com/theia-hq/swoosh/blob/main/docs/reference/commands/identity.md)
   prints its key.
2. The authkey: run `swoosh mint ci-runner` on that laptop. It prints the authkey and records the contact
   `me/ci-runner`, the name you dial later.
3. A GitHub repository you can set secrets on. With the [`gh` CLI](https://cli.github.com) installed, run
   `gh secret set THEIA_AUTHKEY` and paste the authkey; or add it in the repository under Settings >
   Secrets and variables > Actions. The workflow reads it as `${{ secrets.THEIA_AUTHKEY }}`.
4. A Linux or macOS runner. GitHub-hosted runners need no setup. A self-hosted runner needs the `gh` CLI
   on `PATH`, because the install step verifies the binary's provenance with `gh attestation verify`.

## Serve more than a shell

Every entry is `name=target`, space-separated; a bare `ping` or `ping:` is refused. Replace the default
set to add the services you need:

```yaml
- uses: theia-hq/swoosh-action@v2
  with:
    authkey: ${{ secrets.THEIA_AUTHKEY }}
    services: "ssh=sshd: fetch=fetch:https://news.example web=127.0.0.1:8080 sock=unix:/path"
```

Every service sits behind the same gate, and the keyless shell has no public form: `swoosh serve` refuses
`--public` for `sshd:`. The set you can serve depends on the swoosh release the action installs
([Choose the swoosh version](#choose-the-swoosh-version) pins it). The
[services catalog](https://github.com/theia-hq/swoosh/blob/main/docs/reference/services.md) lists every
target and how it is gated, and
[`swoosh serve`](https://github.com/theia-hq/swoosh/blob/main/docs/reference/commands/serve.md) has the
full `name=target` grammar.

## Hold the job open

Without `minutes` the action returns once the node is up: the node keeps serving in the background and the
workflow moves on to your next steps. With `minutes`, the step stays alive until the hold runs out or the
node is stopped early. From your laptop:

```sh
swoosh stop me/ci-runner          # the v0.8.0 client
swoosh stop --at me/ci-runner     # a client built from main, newer than v0.8.0
```

Either form reaches the node's gated control service and tears it down; the action logs `released early.`
and the step passes. The action checks the serve process is alive before it reports the node reachable,
and keeps checking during the hold, so a node that died fails the step with the redacted error instead of
a blind sleep.

## Reach it

```sh
swoosh ssh me/ci-runner      # a keyless shell in the runner
swoosh ping me/ci-runner     # round-trip time
swoosh speed me/ci-runner    # throughput
```

The action reports the node reachable once the serve process is up. Over iroh a session often starts
relayed and hole-punches to a direct path, so a `swoosh ping` run can read `(upgraded from relayed)`
mid-run, and `swoosh status me/ci-runner` names the path you are on. From your laptop, run
`swoosh ping me/ci-runner` to confirm reachability before a later step depends on the node.

## Rotate the authkey

Mint a fresh authkey per use or per repo, then update the secret:

```sh
swoosh mint ci-runner
gh secret set THEIA_AUTHKEY
```

The authkey carries the device's derived seed and trust for your signet, never your signet key, so a
leaked authkey compromises that one runner and not your identity. It stays adoptable until the membership
badge it carries expires, so mint right before you deploy. The v0.8.0 client mints a one-year badge and
has no `--expires`; a client built from `main`, newer than v0.8.0, takes it and defaults to 90 days
(`swoosh mint ci-runner --expires 30d`).

## Choose the swoosh version

```yaml
- uses: theia-hq/swoosh-action@v2
  with:
    authkey: ${{ secrets.THEIA_AUTHKEY }}
    version: v0.8.0
```

`latest` installs the newest release, so what runs changes over time; a release tag keeps runs
reproducible. Whichever you choose, the install checks the published `.sha256` and verifies the
build-provenance attestation with `gh attestation verify` before the binary runs, so a swapped release
asset is refused.

## The full node key never reaches the log

The action serves with `--quiet`, so the readiness banner (the full node key, the service list, the gate)
never prints. On a failure it rewrites every `bf01...` in the node's stderr to `bf01<redacted>` before
echoing it. `adopt` prints a short label for the device, not the address, and the name you dial was minted
on your laptop before the job started, so there is nothing in the log to read back to reach the node.

## Self-hosted runners

On a runner that persists between jobs, the swoosh binary stays installed in `/usr/local/bin`, and the
next job's `adopt` replaces the previous identity with the authkey that run provides. Set `minutes` so
each hold ends itself; without it the node keeps serving after the step returns, and the action does not
stop a node left by an earlier job.

## Debug a runner

Trigger the Quickstart workflow by hand to `swoosh ssh me/ci-runner` into a live runner
(`gh workflow run swoosh.yml`). To shell into a failed runner instead, add the action step to a real job
with `if: failure()`:

```yaml
- if: failure()
  uses: theia-hq/swoosh-action@v2
  with:
    authkey: ${{ secrets.THEIA_AUTHKEY }}
    minutes: 20
```

A job's `timeout-minutes` is a hard cap; the action's own hold is `minutes`.

## Troubleshooting

### `error: unexpected argument '--at' found`

The `swoosh stop` spelling follows your laptop client, not the action. The v0.8.0 client takes the peer
positionally:

```text
$ swoosh stop --at me/ci-runner
error: unexpected argument '--at' found
```

Run `swoosh stop me/ci-runner` instead. A client built from `main`, newer than v0.8.0, is the other way
around and refuses the bare peer:

```text
$ swoosh stop me/ci-runner
error: unexpected argument 'me/ci-runner' found
```

`swoosh stop --help` shows the form your client takes.

### Error: could not stop

```text
Error: could not stop bf01ueeh4voppqeaupfwi5s3v7mosvvoqjvhclnan7qnf5wbfy6gyutq: stream
```

The stop can land while the v0.8.0 client reports the failed stream open: the node was already tearing
down. The action log shows `released early.` and the step passes, and `swoosh status me/ci-runner` then
reports `unreachable`, so the node is gone despite the client's error.

### Error: not an authkey

```text
Error: not an authkey (expected the `authkey:` prefix)
```

The `swoosh adopt` step failed because the secret does not hold the value `swoosh mint` printed. The
usual cause is a missing or renamed secret: `${{ secrets.THEIA_AUTHKEY }}` evaluates to empty, and
`adopt` rejects the empty value. A truncated paste, a capability link (`sheer:...`), or a path fails the
same way. Set the repository secret to the whole minted value, under the name the workflow references:

```sh
gh secret set THEIA_AUTHKEY
```

The other parse failures (`malformed authkey ...`, `invalid base32 in authkey seed`, `authkey seed is not
32 bytes`, `invalid signet in authkey`) have the same fix. Secrets are not passed to workflows triggered
by pull requests from forks, so the action cannot run there.

### The hold ended early

`released early.` with a passing step means the node was stopped, from your laptop or at the deadline:
that is the intended release. If the step instead fails with `::error::the node exited before the hold
ended.` or `::error::swoosh serve exited immediately.`, the node exited nonzero and the redacted stderr
below the error names why (`bf01...` is scrubbed to `bf01<redacted>`).
