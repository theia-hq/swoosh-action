# swoosh-action

A GitHub Action that turns a CI runner into a node you reach by its public key: across GitHub's NAT, with
no port-forward and no SSH keys to manage. Mint the runner's name on your laptop before the runner exists,
then dial `me/ci-runner` while the job runs.

## Quickstart

This workflow serves the default set (a keyless shell, `ping`, and `speed`) and holds the runner open for
`30m`:

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
          expires: 30m
```

Save it as `.github/workflows/swoosh.yml`, push it to your default branch, then run it from the Actions
tab or with `gh workflow run swoosh.yml`.

`authkey` is optional. Set it to the value `swoosh mint` printed: the runner adopts it to become the
device identity [`swoosh mint`](https://github.com/theia-hq/swoosh/blob/main/docs/reference/commands/mint.md)
derived and to trust the root key that minted it (your signet), so its gate admits your devices and the
delegates you grant. The authkey carries a device seed: keep it in a repository secret, never in the
workflow file. The action pipes the secret into `adopt` on stdin, so it never enters the command line or a
file, and unsets the environment variable before any other process starts. Omit it to
[run self-rooted](#self-rooted-nodes) instead. [Prerequisites](#prerequisites) has the commands that
produce it.

`services` is optional and defaults to `ssh=sshd: ping=ping: speed=speed:`.
[Serve more than a shell](#serve-more-than-a-shell) has the grammar, examples, and reference links.

`public` is optional and empty by default: every service stays behind your gate. Set it to a
comma-separated list of services to open to anyone, exactly as `swoosh serve --public` takes them (e.g.
`ping,speed`). Only `ping`, `speed`, and `fetch` may be opened, and each must be bound to its matching
built-in target in `services`: `ping=ping:`, `speed=speed:`, or `fetch=fetch:<origin>`. Any other shape,
including a forward, `echo`, a raw stream, a `--public-unsafe` shape, a name bound to another target, or a
name you do not serve, is refused before serve runs. The node enforces `fetch`'s origin scope.
[Open a service to anyone](#open-a-service-to-anyone) has the details.

`expires` is optional and unset by default. Set a duration (`30m`, `2h`, `1d`, as `swoosh serve --expires`
parses) to bound the node: the step then runs serve in the foreground and lives exactly as long as the
node. Omit it and the step returns once the node is up, with the node serving until the job ends. It is
refused without an `authkey` (a self-rooted node is reached by a link later steps mint).
[Hold the job open](#hold-the-job-open) has the details.

`version` is optional and defaults to `latest`, the newest swoosh release. Set a release tag such as
`v0.8.0` to pin it. [Choose the swoosh version](#choose-the-swoosh-version) covers the install check.

## Prerequisites

1. A laptop with the [`swoosh`](https://github.com/theia-hq/swoosh) client installed. Get a binary from
   the [releases](https://github.com/theia-hq/swoosh/releases) page. The client mints your signet (your
   root key) on first use, and
   [`swoosh identity`](https://github.com/theia-hq/swoosh/blob/main/docs/reference/commands/identity.md)
   prints its key.
2. The authkey: run `swoosh mint ci-runner` on that laptop. It prints the authkey and records the contact
   `me/ci-runner`, the name you dial later. A [self-rooted node](#self-rooted-nodes) skips this.
3. A Linux or macOS runner and a GitHub repository you can set secrets on. With the [`gh`
   CLI](https://cli.github.com) installed, run `gh secret set THEIA_AUTHKEY` and paste the authkey; or add
   it in the repository under Settings > Secrets and variables > Actions. The workflow reads it as
   `${{ secrets.THEIA_AUTHKEY }}`.

## Serve more than a shell

Every entry is `name=target`, space-separated; a bare `ping` or `ping:` is refused. Replace the default
set to add the services you need:

```yaml
- uses: theia-hq/swoosh-action@v2
  with:
    authkey: ${{ secrets.THEIA_AUTHKEY }}
    services: "ssh=sshd: fetch=fetch:https://news.example web=127.0.0.1:8080 sock=unix:/path"
```

The set you can serve depends on the swoosh release the action installs
([Choose the swoosh version](#choose-the-swoosh-version) pins it). The
[services catalog](https://github.com/theia-hq/swoosh/blob/main/docs/reference/services.md) lists every
target and how it is gated, and
[`swoosh serve`](https://github.com/theia-hq/swoosh/blob/main/docs/reference/commands/serve.md) has the
full `name=target` grammar.

## Reach a service the job runs

The job can serve a local port (a preview build, a dashboard): set `services: "web=127.0.0.1:8080"`,
which replaces the default set, and keep the job open for the review window. On your laptop,
`swoosh grant issue web --expires 4h` mints a capability link and `swoosh contact ls me` prints the
runner's full key; hand reviewers this line:

```sh
swoosh forward <node-key> --service web --to 8080 --present sheer:<link>
```

Then open `http://127.0.0.1:8080`. `forward` dials anonymously by construction, so the link is the way in
even for your own devices; it reaches only `web` and expires with the window. Secrets do not reach fork
pull requests, so this is for same-repo branches.

## Open a service to anyone

Every service is gated by default: only your own devices and the delegates you grant reach any of them.
Set `public` to open named services to anyone, unauthenticated:

```yaml
- uses: theia-hq/swoosh-action@v2
  with:
    authkey: ${{ secrets.THEIA_AUTHKEY }}
    services: "ping=ping: speed=speed: fetch=fetch:https://news.example"
    public: ping,speed,fetch
```

Only the names you list are opened, and each must be a service you serve. The eligible set is exactly
`ping=ping:`, `speed=speed:`, and `fetch=fetch:<origin>`: the name must be bound to its matching built-in
target in `services`, so a public `fetch` requires an entry like `fetch=fetch:https://news.example`. Any
other shape is refused before `serve` runs, including a forward, `echo`, a raw stream
(`file:`/`fifo:`/`stdin:`), a name bound to another target, a name you do not serve, and anything shaped
like `--public-unsafe`. The node enforces `fetch`'s origin scope: an origin-scoped fetch opens, and a bare
`fetch:` is refused at startup as an open relay. A public `ping` or `speed` is metered by the node: a
per-caller run interval, one transfer at a time, and byte and wall-clock caps.

**The honest limit.** A public service is reachable by anyone who knows the node's key. There is no link
to expire and no badge to revoke; `expires` or the end of the job is the bound. The key is public by
design and grants nothing for the gated services.

[Public service](https://github.com/theia-hq/swoosh/blob/main/docs/use-cases/public-service.md) covers
`--public` on a node you run yourself.

## Hold the job open

Set `expires` to a duration (`30m`, `2h`, `1d`): the step then runs `swoosh serve` in the foreground and
lives exactly as long as the node. At the deadline, or on a remote stop, the node ends gracefully and the
step passes; a real serve failure fails the step with the redacted stderr.

Omit `expires` and the step returns once the node is up, while the node keeps serving until the job ends.
The action checks the node is alive before it reports it reachable, so a node that died at startup fails
the step with the redacted error. On a self-hosted runner, the action warns that no deadline is set.

From your laptop, end the node early:

```sh
swoosh stop --at me/ci-runner
```

The stop reaches the node's gated control service and tears it down; with `expires` set, the step then
passes.

## Reach it

```sh
swoosh ssh me/ci-runner      # a keyless shell in the runner
swoosh ping me/ci-runner     # round-trip time
swoosh speed me/ci-runner    # throughput
```

Without `expires` the action reports the node reachable once serve is up, and the node keeps serving until
the job ends. With `expires` the step is the node running, so connect while the step runs. Over iroh a
session often starts relayed and hole-punches to a direct path, so a `swoosh ping` run can read
`(upgraded from relayed)` mid-run, and `swoosh status me/ci-runner` names the path you are on. From your
laptop, run `swoosh ping me/ci-runner` to confirm reachability before a later step depends on the node.

For the end-to-end deployment, the [`theia-hq/qat`](https://github.com/theia-hq/qat) template runs this
action on demand to give a developer a keyless shell on a runner.

## Let the job reach your machines

The runner is a member device, so it can dial out as well as be dialed. Serve a receiver on one of your
machines (`swoosh serve recv=recv:/srv/releases`) and run the action non-blocking: it returns while the
workflow advances, and a later step pushes the artifact. The runner's contact store is empty after
`adopt`, so name the peer by key (or add it once):

```sh
swoosh contact add deploybox bf01<box-key>
swoosh send app.tar deploybox
```

Each file is verified end to end on arrival, and the box's gate admits the runner by its membership
badge. The same step can run `swoosh ssh deploybox -- <command>` instead. The full walkthrough is
[Use swoosh from CI](https://github.com/theia-hq/swoosh/blob/main/docs/use-cases/ci-runner.md).

## Outputs

The action publishes two outputs for a later step to compose instructions or a PR comment. Give the action
step an `id` (here `node`), then read them in a later step:

```yaml
      - id: node
        uses: theia-hq/swoosh-action@v2
        with:
          authkey: ${{ secrets.THEIA_AUTHKEY }}
      - run: echo "node ${{ steps.node.outputs['node-id'] }} serves ${{ steps.node.outputs.services }}"
```

- `node-id`: the node's public key (`bf01...`), the address peers dial. In adopt mode it is the adopted
  device's key; self-rooted, the key the runner just minted.
- `services`: the services the node serves, `name=target`, exactly as passed to the action (the input or
  its default).

Both are public: no capability link is minted or emitted by the action. Without `expires` they settle
while the node is still serving; with `expires`, when the node ends cleanly.

## Self-rooted nodes

Leave `authkey` empty and the runner roots itself: it mints its own key and trusts only that key, so none
of your devices reach it by membership. The action warns in the log that the node trusts only its own root,
so your devices will not reach it, and that setting the authkey secret adopts instead. There is no
`me/<label>` contact to dial.

Reach is then a capability link a later step mints and publishes (`swoosh grant issue <service>`), using
this step's `node-id` output. The later step mints from the same home the node served under: the action
exports `SWOOSH_HOME` for the rest of the job, which the 0.9.0 client honors. An older client ignores it
and reuses the default home, so on a persistent self-hosted runner the node can come up under an earlier
job's identity.

`expires` is refused with an empty `authkey`: a self-rooted node is reached by a link later steps must mint
and publish, and a held step blocks them. Run without `expires`, mint and publish in later steps, and keep
the job alive with a final step.

## Rotate the authkey

Mint a fresh authkey per use or per repo, then update the secret:

```sh
swoosh mint ci-runner
gh secret set THEIA_AUTHKEY
```

The authkey carries the device's derived seed and trust for your signet, never your signet key, so a
leaked authkey compromises that one runner and not your identity. It stays adoptable until the membership
badge it carries expires, so mint right before you deploy. `swoosh mint ci-runner --expires 30d` shortens
the window; the default is 90 days.

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

## The node id is a public key, and the log is public

The node id is a public key, not a secret: knowing it grants nothing without a badge from your signet (or
a capability link when the node is self-rooted), and every service stays behind the gate. The action still
serves with `--quiet`, because a CI log is a public record: the readiness banner (the full node key, the
service list, the gate) never prints, and an accidental `cat` cannot republish the node's address. On a
failure the action rewrites every `bf01...` in the node's stderr to `bf01<redacted>` before echoing it.

In adopt mode, `adopt` prints the derived device's short label (like `bf01ueeh4voppqea`), never the full
node key. The full key is the address a stranger would dial, and it stays on the two machines that need
it: the node's home and your contacts. Your own terminal or a private log is a fine place to show it; a
public CI log is not. Unlike tmate's printed connection string, nothing has to be read back from the log
to reach the node.

## Self-hosted runners

On a runner that persists between jobs, the swoosh binary stays installed in `/usr/local/bin`, and the
next job's `adopt` replaces the previous identity with the authkey that run provides. A self-hosted runner
needs the `gh` CLI on `PATH`, because the install step verifies the binary's provenance with
`gh attestation verify`. Set `expires` so the node carries its own deadline and no node outlives the job;
without it the action warns that no deadline is set and the node serves until the job ends. The action
does not stop a node left by an earlier job.

## Debug a runner

Trigger the Quickstart workflow by hand to `swoosh ssh me/ci-runner` into a live runner
(`gh workflow run swoosh.yml`). To shell into a failed runner instead, add the action step to a real job
with `if: failure()`:

```yaml
- if: failure()
  uses: theia-hq/swoosh-action@v2
  with:
    authkey: ${{ secrets.THEIA_AUTHKEY }}
    expires: 20m
```

A job's `timeout-minutes` is a hard cap; the action's own deadline is `expires`.

## Troubleshooting

### Error: not an authkey

```text
Error: not an authkey (expected the `authkey:` prefix)
```

The secret is set but does not hold the value `swoosh mint` printed: a truncated paste, a capability link
(`sheer:...`), or a path. Set the repository secret to the whole minted value, under the name the workflow
references:

```sh
gh secret set THEIA_AUTHKEY
```

An empty secret is not this error: the node self-roots with a warning. The other parse failures
(`malformed authkey ...`, `invalid base32 in authkey seed`, `authkey seed is not 32 bytes`, `invalid signet
in authkey`) have the same fix. Secrets are not passed to workflows triggered by pull requests from forks,
so a fork run self-roots with the warning instead of adopting your signet.

### The node exited early

With `expires`, the node ends at its deadline or on a remote stop and the step passes; a real serve
failure fails the step with `::error::swoosh serve exited ...` and the redacted stderr below it. Without
`expires`, a node that dies in the first two seconds fails the step with
`::error::swoosh serve exited immediately.`, or prints `released early.` when a stop landed in that window.
In every failure the stderr names the cause with `bf01...` scrubbed to `bf01<redacted>`.
