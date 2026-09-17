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

# The host of a `fetch:` origin, as the node's URL parser would read it: scheme off, path and query off,
# port off, brackets KEPT so an IPv6 literal stays recognizable. Userinfo never reaches here (it is refused
# first), so an `@` cannot move which side of the string is the host.
origin_host() {
  local host="${1#*://}"
  host="${host%%[/?#]*}"
  case "$host" in
    "["*) host="${host%%]*}]" ;;
    *) host="${host%%:*}" ;;
  esac
  printf '%s' "$host"
}

# True when a host is one only the runner could reach. A NAME is never decided here: it resolves at fetch
# time, where the engine checks the ADDRESS it actually got, so `10.example.com` is not refused for looking
# numeric. A LITERAL is decided in every spelling the URL parser accepts, because the operator wrote it and
# a service bound to it would advertise itself as open and then refuse every request.
is_private_host() {
  local host stripped field saved_ifs
  host="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  # A resolver reads `localhost.` as `localhost`.
  while [ "${host%.}" != "$host" ]; do host="${host%.}"; done
  case "$host" in
    localhost | *.localhost) return 0 ;;
  esac
  case "$host" in
    "["*)
      host="${host#"["}"
      host="${host%%]*}"
      # An embedded IPv4 (`::ffff:127.0.0.1`, the NAT64 `64:ff9b::169.254.169.254`) is decided by its v4
      # half, whatever prefix stands in front of it.
      case "$host" in
        *:*.*.*.*)
          is_private_host "${host##*:}" && return 0
          ;;
      esac
      # Loopback and unspecified in ANY spelling: drop every `0` and `:`, and `::`, `0:0:0:0:0:0:0:0` and
      # friends leave nothing, while `::1` and `0:0:0:0:0:0:0:1` leave a `1` the literal also ends with
      # (so `1::`, which is a different address, is not caught by the same test).
      stripped="$(printf '%s' "$host" | tr -d '0:')"
      case "$stripped" in
        "") return 0 ;;
        1) case "$host" in *1) return 0 ;; esac ;;
      esac
      # Link-local is fe80::/10 (fe80 through febf); unique-local is fc00::/7 (fc00 through fdff). Match the
      # whole first hextet, not the one spelling `fe80:`.
      case "$host" in
        fe[89ab][0-9a-f]:* | f[cd][0-9a-f][0-9a-f]:*) return 0 ;;
      esac
      return 1
      ;;
  esac
  case "$host" in
    # A hex host (`0x7f000001`, `0x7f.0.0.1`) is an address the parser decodes and a person cannot read.
    # Refuse the spelling rather than decode it here.
    0x* | *.0x*) return 0 ;;
    # Anything holding a character that is not a digit or a dot is a NAME: the engine owns it.
    *[!0-9.]*) return 1 ;;
  esac
  # Digits and dots only, so this is an IPv4 literal. Only a canonical dotted quad is read further: a bare
  # integer (`2130706433`), a short form (`10.1`), or a leading-zero octet (`0177.0.0.1`, which the parser
  # reads as OCTAL 127) is refused as a spelling nobody should have to decode.
  saved_ifs="$IFS"
  IFS='.'
  set -- $host
  IFS="$saved_ifs"
  [ "$#" -eq 4 ] || return 0
  for field in "$@"; do
    case "$field" in
      "" | *[!0-9]*) return 0 ;;
      0 | [1-9]*) ;;
      *) return 0 ;;
    esac
    [ "$field" -le 255 ] || return 0
  done
  case "$host" in
    # The ranges no caller could route to: loopback, this-network, RFC1918, link-local (which includes the
    # 169.254.169.254 metadata address), and CGNAT. The same ranges the fetch engine refuses at connect time.
    127.* | 0.* | 10.* | 169.254.* | 172.1[6-9].* | 172.2[0-9].* | 172.3[01].* | 192.168.* | \
    100.6[4-9].* | 100.[7-9][0-9].* | 100.1[01][0-9].* | 100.12[0-7].*) return 0 ;;
  esac
  return 1
}

# A block-scalar list can hide names past the first line; refuse it here, not at serve.
case "$public" in
  *$'\n'*)
    echo "::error::public: the list must be one line; a newline is not allowed."
    exit 1
    ;;
esac

# An empty token is refused HERE, on the raw string, because the split hides one: bash `read -ra` DROPS a
# trailing empty field where serve's parser keeps it, so `ping,` would be proven as one name and delivered
# as two. All three spellings (leading, doubled, trailing) are still visible before the split.
case "$public" in
  ,* | *,,* | *,)
    echo "::error::public: the list has an empty name; remove the stray comma."
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
    if is_private_host "$(origin_host "$origin")"; then
      echo "::error::public: fetch origin '$origin' is on the runner's own network, or is an address spelled so it does not read as one; a public fetch must name an origin its callers could reach themselves."
      exit 1
    fi
  fi
done
