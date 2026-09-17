#!/usr/bin/env bash
# The action-side half of the eligible-set guard: decide which services the `public:` input may open to
# anyone, and refuse the whole run before `swoosh serve` binds anything. The exclusion lives in the input
# parse, so manual `swoosh serve --public` semantics stay untouched; the node's own bind proof still
# backstops the target level.
#
# Usage: public-guard.sh <public-list> [<name=target> ...]
#   $1 is the `public:` input verbatim (a comma-list, exactly as `swoosh serve --public` takes it).
#   The rest are the service entries as the SAME words serve receives, so the guard proves the list the
#   node actually binds; the two cannot drift apart into a proof of something that is not served.
#
# Exit 0 when every public name is eligible, 1 with a `::error::` annotation naming the first offender,
# 2 on misuse. Its decisions are the test matrix in scripts/test-public-guard.rb; a guard nothing
# exercises is a guard that regresses silently.
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "::error::public-guard: usage: public-guard.sh <public-list> [<name=target> ...]" >&2
  exit 2
fi
public="$1"
shift

# Nothing listed is nothing to prove: every service stays behind the node's gate.
[ -n "$public" ] || exit 0

PUBLIC_RULE="The eligible set is exactly ping=ping:, speed=speed:, and fetch=fetch:<origin>; forwards, echo, raw streams, and --public-unsafe are never eligible."

# The host of a `fetch:` origin, read the way the node's allowlist reads it: scheme off, path/query off,
# port off, IPv6 brackets off, lowercased. Userinfo never reaches here (it is refused above), so an `@`
# cannot move which side of the string is the host.
origin_host() {
  local host="${1#*://}"
  host="${host%%[/?#]*}"
  case "$host" in
    "["*)
      host="${host#"["}"
      host="${host%%]*}"
      ;;
    *) host="${host%%:*}" ;;
  esac
  printf '%s' "$host" | tr '[:upper:]' '[:lower:]'
}

# A block-scalar list can hide names past the first line; refuse it here, not at serve.
case "$public" in
  *$'\n'*)
    echo "::error::public: the list must be one line; a newline is not allowed."
    exit 1
    ;;
esac

# Split on commas only; no trimming, so a token is compared exactly as typed (` speed` is not `speed`).
IFS=',' read -ra PUBLIC_NAMES <<< "$public"
for name in "${PUBLIC_NAMES[@]}"; do
  # A public name must be ping, speed, or fetch AND bound to its matching built-in target, so an alias
  # (`fetch=127.0.0.1:8080`) or a forward cannot ride a built-in name.
  case "$name" in
    ping | speed | fetch) ;;
    *)
      echo "::error::public: '$name' is not eligible. $PUBLIC_RULE"
      exit 1
      ;;
  esac
  entry= target=
  # Scan the WHOLE list rather than stopping at the first match: `ping=ping: ping=file:/etc/passwd` would
  # otherwise be proven on its first entry, and whether the second one ever binds would rest on the node
  # refusing a duplicate name. It does, but a guard whose verdict depends on a downstream refusal is a
  # guard with an undocumented dependency, so the ambiguity is refused here.
  for candidate in "$@"; do
    case "$candidate" in
      "$name"=*)
        if [ -n "$entry" ]; then
          echo "::error::public: '$name' is served twice ('$entry' and '$candidate'); a name may map to only one target."
          exit 1
        fi
        entry="$candidate"
        target="${candidate#*=}"
        ;;
    esac
  done
  if [ -z "$entry" ]; then
    echo "::error::public: '$name' is not served: no '$name=<target>' entry in services. $PUBLIC_RULE"
    exit 1
  fi
  # The binding must be EXACT, not a prefix. A prefix test accepts `ping=ping:80`, which tightbeam's
  # target grammar reads as host:port: the node binds a local FORWARD named `ping`, and the public proof
  # opens it because the NAME is eligible. `ping` and `speed` take no argument, so their whole target is
  # the literal scheme; `fetch` is scoped to the origin it carries, so it needs a non-empty remainder (a
  # bare `fetch:` is an open relay, which the node refuses at startup anyway).
  case "$entry" in
    ping=ping: | speed=speed: | fetch=fetch:?*) ;;
    *)
      echo "::error::public: '$name' is bound to '$target', which is not its built-in target. $PUBLIC_RULE"
      exit 1
      ;;
  esac
  # An open fetch is an egress hop FROM the runner's network, so its origin must be somewhere the caller
  # could already reach on their own. An origin on the runner's loopback, its LAN, or the cloud metadata
  # address is refused here: the fetch engine re-resolves and re-checks every address before it connects,
  # so such a service would bind, advertise itself as open, and then refuse every request. Refuse the
  # configuration rather than publish one that cannot work, and do not lean on the engine's own check.
  if [ "$name" = fetch ]; then
    origin="${target#fetch:}"
    hostport="${origin#*://}"
    case "${hostport%%[/?#]*}" in
      *@*)
        # Userinfo. The node refuses such an origin whole rather than parsing around it, because either
        # side can be dressed as the other (`https://allowed@evil/`, `https://evil@allowed/`).
        echo "::error::public: fetch origin '$origin' carries userinfo; name the host alone."
        exit 1
        ;;
    esac
    host="$(origin_host "$origin")"
    private=false
    case "$host" in
      localhost | *.localhost) private=true ;;
    esac
    case "$host" in
      # Not an address at all (it holds something other than digits and dots): a name resolves at fetch
      # time, where the engine checks the ADDRESS it actually got, so `10.example.com` is not refused here
      # for merely looking numeric.
      *[!0-9.]*) ;;
      # The IPv4 literals no caller could route to: loopback, this-network, RFC1918, link-local (which
      # includes the 169.254.169.254 metadata address), and CGNAT. The same ranges the engine refuses.
      127.* | 0.* | 10.* | 169.254.* | 172.1[6-9].* | 172.2[0-9].* | 172.3[01].* | 192.168.* | \
      100.6[4-9].* | 100.[7-9][0-9].* | 100.1[01][0-9].* | 100.12[0-7].*) private=true ;;
    esac
    case "$host" in
      # The IPv6 literals: loopback, unspecified, link-local (fe80::/10), unique-local (fc00::/7). Each
      # pattern needs a colon, which a hostname cannot carry.
      ::1 | :: | fe80:* | fc*:* | fd*:*) private=true ;;
    esac
    if [ "$private" = true ]; then
      echo "::error::public: fetch origin '$origin' is on the runner's own network; a public fetch must name an origin its callers could reach themselves."
      exit 1
    fi
  fi
done
