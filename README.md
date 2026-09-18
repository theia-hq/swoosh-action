# swoosh-action

A GitHub Action that turns a CI runner into a node you reach by its public key: across GitHub's NAT, with
no port-forward and no SSH keys to manage. Create the runner's invite on your machine before the runner
exists, then dial `me/ci-runner` while the job runs.

This page describes the default branch; the released docs are at the newest tag.

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
          invite: ${{ secrets.THEIA_INVITE }}
          expires: 30m
```

Save it as `.github/workflows/swoosh.yml`, push it to your default branch, then run it from the Actions
tab or with `gh workflow run swoosh.yml`.

`invite` is optional. Set it to the invite `swoosh invite add` printed: the runner adopts it to become
the device identity [`swoosh invite add`](https://github.com/theia-hq/swoosh/blob/main/docs/reference/commands/invite.md)
derived and to trust the root key that minted it (your signet), so its gate admits your devices and the
delegates you grant. The invite carries a device seed: keep it in a repository secret, never in the
workflow file. The action pipes the secret into `adopt` on stdin, so it never enters the command line or a
file, and unsets the environment variable before any other process starts. Omit it to
[run self-rooted](#self-rooted-nodes) instead. [Prerequisites](#prerequisites) has the commands that
produce it.

`services` is optional and defaults to `ssh=sshd: ping=ping: speed=speed:`.
[Serve more than a shell](#serve-more-than-a-shell) has the grammar, examples, and reference links.

`public` is optional and empty by default: every service stays behind your gate. Set it to a
comma-separated list of services to open to anyone, exactly as `swoosh serve --public` takes them (e.g.
`ping,speed`). A runner sits inside a network, and `public` means anyone on the internet can reach that
service with no credential. [Open a service to anyone](#open-a-service-to-anyone) has the details.

`expires` is optional and unset by default. Set a duration (`30m`, `2h`, `1d`, as `swoosh serve --expires`
parses) to bound the node: the step then runs serve in the foreground and lives exactly as long as the
node. Omit it and the step returns once the node is up, with the node serving until the job ends. It is
refused without an `invite` (a self-rooted node is reached by a link later steps mint).
[Hold the job open](#hold-the-job-open) has the details.

`relay` is optional and empty by default, so n0's public relays carry the fallback. Set it to a relay you
run (`iroh-relay`, e.g. `https://relay.example`) and this runner offers that relay in the record it
publishes, so peers dial it through yours.

`resolver` is optional and empty by default, so the runner publishes its address record to n0's public
discovery. Set it to the `/pkarr` URL of a resolver you run (`iroh-dns-server`, e.g.
`https://dns.example/pkarr`); your own machines find the runner only if they resolve through the same one.
[Run the relay and the resolver yourself](https://github.com/theia-hq/swoosh/blob/main/docs/transports.md#self-run)
covers both.

`version` is optional and defaults to `latest`, the newest swoosh release. Set a release tag such as
`v0.9.0` to pin it. [Choose the swoosh version](#choose-the-swoosh-version) covers the install check.

## Prerequisites

1. A machine with the [`swoosh`](https://github.com/theia-hq/swoosh) client installed. Get a binary from
   the [releases](https://github.com/theia-hq/swoosh/releases) page. The client mints your signet (your
   root key) on first use, and
   [`swoosh identity`](https://github.com/theia-hq/swoosh/blob/main/docs/reference/commands/identity.md)
   prints its key.
2. The invite: run `swoosh invite add ci-runner` on that machine. It prints a one-time invite and records
   the contact `me/ci-runner`, the name you dial later. A [self-rooted node](#self-rooted-nodes) skips this.
3. A Linux or macOS runner and a GitHub repository you can set secrets on. With the [`gh`
   CLI](https://cli.github.com) installed, run `gh secret set THEIA_INVITE` and paste the invite; or add
   it in the repository under Settings > Secrets and variables > Actions. The workflow reads it as
   `${{ secrets.THEIA_INVITE }}`.

## Serve more than a shell

Every entry is `name=target`, space-separated. Replace the default set to add the services you need:

```yaml
- uses: theia-hq/swoosh-action@v2
  with:
    invite: ${{ secrets.THEIA_INVITE }}
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
which replaces the default set, and `expires: 4h` to hold the job open for the review window. On the
machine that holds your signet, `swoosh grant issue web --expires 4h` mints a capability link and
`swoosh contact ls me` prints the runner's full key; hand reviewers this line (they need the `swoosh`
client installed):

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
    invite: ${{ secrets.THEIA_INVITE }}
    services: "ping=ping: speed=speed: fetch=fetch:https://news.example"
    public: ping,speed,fetch
```

A runner sits inside a network. `public` means anyone on the internet can reach that service with no
credential, and the node opens anything it considers safe to open, including a port forward into the
network the job runs in. The action does not narrow the list: it hands it to `swoosh serve --public`
exactly as you wrote it, and the node proves every name at startup, before it announces anything, and
refuses what has no safe public form. Name only what you meant.

**A public service is reachable by anyone who knows the node's key.** There is no link
to expire and no badge to revoke; `expires` or the end of the job is the bound. The key is public by
design and grants nothing for the gated services.

[`swoosh serve`](https://github.com/theia-hq/swoosh/blob/main/docs/reference/commands/serve.md) has what
each service opens to a stranger and what `--public` refuses;
[Public service](https://github.com/theia-hq/swoosh/blob/main/docs/use-cases/public-service.md) covers
`--public` on a node you run yourself.

## Hold the job open

Set `expires` to a duration (`30m`, `2h`, `1d`): the step then runs `swoosh serve` in the foreground and
lives exactly as long as the node. At the deadline, or on a remote stop, the node ends gracefully and the
step passes; a real serve failure fails the step with the redacted stderr.

Omit `expires` and the step returns once the node is up, while the node keeps serving until the job ends.
The action checks the node is alive before it reports it reachable, so a node that died at startup fails
the step with the redacted error. On a self-hosted runner, the action warns that no deadline is set.

From your machine, end the node early:

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
the job ends. With `expires` the step is the node running, so connect while the step runs. Run
`swoosh ping me/ci-runner` to confirm reachability before a later step depends on the node.

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
          invite: ${{ secrets.THEIA_INVITE }}
      - run: echo "node $NODE_ID serves $SERVICES"
        env:
          NODE_ID: ${{ steps.node.outputs['node-id'] }}
          SERVICES: ${{ steps.node.outputs.services }}
```

Read an output through `env:`, as above, rather than substituting `${{ ... }}` into the script text: an
expression is pasted into the shell before it runs, so a value carrying a quote or a newline becomes part
of the command. That holds for any expression, not just these two.

- `node-id`: the node's public key (`bf01...`), the address peers dial. In adopt mode it is the adopted
  device's key; self-rooted, the key the runner just minted.
- `services`: the services the node serves, `name=target`, exactly as passed to the action (the input or
  its default).

Both are public: no capability link is minted or emitted by the action. Without `expires` they settle
while the node is still serving; with `expires`, when the node ends cleanly.

## Self-rooted nodes

Leave `invite` empty and the runner roots itself: it mints its own key and trusts only that key, so none
of your devices reach it by membership. The action warns in the log that the node trusts only its own root,
so your devices will not reach it, and that setting the invite secret adopts instead. There is no
`me/<label>` contact to dial.

Reach is then a capability link a later step mints and publishes (`swoosh grant issue <service>`), using
this step's `node-id` output. The later step mints from the same home the node served under: the action
exports `SWOOSH_HOME` for the rest of the job, which the 0.9.0 client honors. An older client ignores it
and reuses the default home, so on a persistent self-hosted runner the node can come up under an earlier
job's identity.

`expires` is refused with an empty `invite`: a self-rooted node is reached by a link later steps must mint
and publish, and a held step blocks them. Run without `expires`, mint and publish in later steps, and keep
the job alive with a final step.

## Rotate the invite

Create a fresh invite per use or per repo, then update the secret:

```sh
swoosh invite add ci-runner
gh secret set THEIA_INVITE
```

The invite carries the device's derived seed and trust for your signet, never your signet key, so a
leaked invite compromises that one runner and not your identity. It stays adoptable until the badge it
carries expires, so create it right before you deploy;
[`swoosh invite`](https://github.com/theia-hq/swoosh/blob/main/docs/reference/commands/invite.md) has the
window and how to shorten it.

## Choose the swoosh version

```yaml
- uses: theia-hq/swoosh-action@v2
  with:
    invite: ${{ secrets.THEIA_INVITE }}
    version: v0.9.0
```

`latest` installs the newest release, so what runs changes over time; a release tag keeps runs
reproducible. Whichever you choose, the install checks the published `.sha256` and verifies the
build-provenance attestation with `gh attestation verify` before the binary runs, so a swapped release
asset is refused.

## The node id is a public key, and the log is public

The node id is a public key, not a secret: knowing it grants nothing without a badge from your signet (or
a capability link when the node is self-rooted), and every gated service stays behind the gate. The
exception is a service you name in [`public`](#open-a-service-to-anyone): the key is all anyone needs to
reach that one, so publish it only if you meant to. The action still
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
next job's `adopt` replaces the previous identity with the invite that run provides. A self-hosted runner
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
    invite: ${{ secrets.THEIA_INVITE }}
    expires: 20m
```

A job's `timeout-minutes` is a hard cap; the action's own deadline is `expires`.

## Troubleshooting

### Error: not an invite

```text
Error: not an invite (expected the `invite:` prefix)
```

The secret is set but does not hold the value `swoosh invite add` printed: a truncated paste, a capability
link (`sheer:...`), or a path. Set the repository secret to the whole printed invite, under the name the
workflow references:

```sh
gh secret set THEIA_INVITE
```

An empty secret is not this error: the node self-roots with a warning. Every other invite parse failure
has the same fix. Secrets are not passed to workflows triggered by pull requests from forks, so a fork run
self-roots with the warning instead of adopting your signet.

### The node exited early

With `expires`, the node ends at its deadline or on a remote stop and the step passes; a real serve
failure fails the step with `::error::swoosh serve exited ...` and the redacted stderr below it. Without
`expires`, a node that dies in the first two seconds fails the step with
`::error::swoosh serve exited immediately.`, or prints `released early.` when a stop landed in that window.
In every failure the stderr names the cause with `bf01...` scrubbed to `bf01<redacted>`.
