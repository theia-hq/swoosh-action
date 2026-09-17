#!/usr/bin/env ruby
# frozen_string_literal: true

# Exercise the public-input guard's DECISIONS (scripts/public-guard.sh), the check that decides which
# services the action opens to anyone. It runs the real script, once per case, and asserts the verdict:
# a refusal is exit 1 with an `::error::` annotation, an acceptance is exit 0 and silence.
#
# Why a decision table and not a lint: the guard's only job is where it draws the line, and the line moved
# once already (a prefix test accepted `ping=ping:80`, which the node binds as a forward named `ping`).
# Every row below is a line, not a style.
#
# Two more checks ride along, because both protect decisions no test can call directly: action.yml must
# still CALL the guard and must still pass `--` before the services (a dash-leading services token would
# otherwise reach serve as a flag and open what the guard never saw), and, where a swoosh binary exists,
# the binary itself must still treat a post-`--` token as data.
#
# Run: ruby scripts/test-public-guard.rb

require "open3"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
GUARD = File.join(ROOT, "scripts", "public-guard.sh")
ACTION_PATH = File.join(ROOT, "action.yml")

# The action's own `services` default: the node the guard sees when a caller sets only `public`.
DEFAULT = ["ssh=sshd:", "ping=ping:", "speed=speed:"].freeze
FETCH = ["ping=ping:", "fetch=fetch:https://news.example"].freeze

Case = Struct.new(:verdict, :why, :public, :services)

CASES = [
  # Accepted: a built-in name bound to its exact built-in target, and nothing else.
  Case.new(:accept, "an empty list opens nothing", "", DEFAULT),
  Case.new(:accept, "ping bound to ping:", "ping", DEFAULT),
  Case.new(:accept, "speed bound to speed:", "speed", DEFAULT),
  Case.new(:accept, "both diagnostics at once", "ping,speed", DEFAULT),
  Case.new(:accept, "fetch scoped to an origin", "fetch", FETCH),
  Case.new(:accept, "an origin with a path is still an origin", "fetch", ["fetch=fetch:https://x/y"]),

  # Refused: the target binding is exact, not a prefix. `ping:80` is a host:port forward to the node.
  Case.new(:refuse, "ping bound to a host:port forward", "ping", ["ping=ping:80"]),
  Case.new(:refuse, "speed bound to a host:port forward", "speed", ["speed=speed:80"]),
  Case.new(:refuse, "fetch with no origin is an open relay", "fetch", ["fetch=fetch:"]),
  Case.new(:refuse, "a built-in name aliased to a local port", "ping", ["ping=127.0.0.1:22"]),
  Case.new(:refuse, "a built-in name aliased to a raw stream", "ping", ["ping=file:/etc/passwd"]),

  # Refused: the name itself is outside the eligible set, whatever it is bound to.
  Case.new(:refuse, "the shell is never eligible", "ssh", DEFAULT),
  Case.new(:refuse, "a forward is never eligible", "web", ["web=127.0.0.1:8080"]),
  Case.new(:refuse, "echo is never eligible", "echo", ["echo=echo:"]),
  Case.new(:refuse, "an eligible name buried in a list", "ping,web", DEFAULT + ["web=127.0.0.1:8080"]),
  Case.new(:refuse, "case matters", "PING", DEFAULT),
  Case.new(:refuse, "the entry is not the name", "ping=ping:", DEFAULT),
  Case.new(:refuse, "no trimming: a space is part of the token", "ping, speed", DEFAULT),
  Case.new(:refuse, "an empty token is not a name", ",", DEFAULT),

  # Refused: a name the node never serves, so there is nothing to prove a binding against.
  Case.new(:refuse, "a name not in services", "ping", ["ssh=sshd:"]),
  Case.new(:refuse, "a name in an empty services list", "ping", []),
  Case.new(:refuse, "a near miss is still not served", "fetch", ["fetcher=fetch:https://x"]),

  # Refused: the same name served twice is ambiguous, whichever entry the node would have bound.
  Case.new(:refuse, "a duplicate name hiding a raw stream", "ping", ["ping=ping:", "ping=file:/etc/passwd"]),
  Case.new(:refuse, "a duplicate name is refused even when both agree", "ping", ["ping=ping:", "ping=ping:"]),

  # A public fetch is an egress hop from the runner's network, so its origin must be one a caller could
  # reach without the runner. A NAME is left to the engine's resolve-time check; an address is not.
  Case.new(:refuse, "loopback", "fetch", ["fetch=fetch:http://127.0.0.1:22"]),
  Case.new(:refuse, "localhost by name", "fetch", ["fetch=fetch:http://localhost:8080"]),
  Case.new(:refuse, "the cloud metadata address", "fetch", ["fetch=fetch:http://169.254.169.254/latest/meta-data"]),
  Case.new(:refuse, "an RFC1918 lan", "fetch", ["fetch=fetch:http://10.0.0.5"]),
  Case.new(:refuse, "the 172.16/12 block", "fetch", ["fetch=fetch:https://172.20.0.1"]),
  Case.new(:refuse, "a home lan", "fetch", ["fetch=fetch:https://192.168.1.1"]),
  Case.new(:refuse, "IPv6 loopback", "fetch", ["fetch=fetch:http://[::1]:8080"]),
  Case.new(:refuse, "IPv6 link-local", "fetch", ["fetch=fetch:http://[fe80::1]"]),
  Case.new(:refuse, "userinfo dressed as the host", "fetch", ["fetch=fetch:https://news.example@127.0.0.1"]),
  Case.new(:refuse, "userinfo at all, as the node refuses it", "fetch", ["fetch=fetch:https://user@news.example"]),
  Case.new(:accept, "just outside RFC1918", "fetch", ["fetch=fetch:https://172.15.0.1"]),
  Case.new(:accept, "a name that merely looks numeric", "fetch", ["fetch=fetch:https://10.example.com"]),
  Case.new(:accept, "an @ in the path is not userinfo", "fetch", ["fetch=fetch:https://news.example/mail@inbox"]),
  Case.new(:accept, "a port and a path", "fetch", ["fetch=fetch:https://news.example:8443/section"]),

  # Refused: a multi-line list can hide names past the first line.
  Case.new(:refuse, "a two-line list", "ping\nspeed", DEFAULT),
  Case.new(:refuse, "a trailing newline is still two lines", "ping\n", DEFAULT)
].freeze

def run_guard(kase)
  output, status = Open3.capture2e("bash", GUARD, kase.public, *kase.services)
  [output, status.exitstatus]
end

def check(kase, findings)
  output, code = run_guard(kase)
  shown = kase.public.inspect
  case kase.verdict
  when :accept
    findings << "public-guard.sh #{shown} (#{kase.why}): expected exit 0, got #{code}: #{output.strip}" unless code.zero?
    findings << "public-guard.sh #{shown} (#{kase.why}): accepted, but printed #{output.strip}" unless output.empty?
  when :refuse
    # Exit 1 specifically: exit 2 is misuse (bad argv) and would pass a "nonzero" test while proving
    # nothing about the decision.
    if code == 1
      findings << "public-guard.sh #{shown} (#{kase.why}): refused without an ::error:: annotation" unless output.include?("::error::")
    else
      findings << "public-guard.sh #{shown} (#{kase.why}): expected a refusal (exit 1), got #{code}: #{output.strip}"
    end
  end
end

def check_syntax(findings)
  _, error, status = Open3.capture3("bash", "-n", GUARD)
  findings << "scripts/public-guard.sh: does not parse: #{error.strip}" unless status.success?
end

# The decisions the step makes in YAML, which no test can call: assert their SHAPE, so a guard that is
# extracted, kept green here, and quietly dropped from the step fails loudly.
def check_step(findings)
  action = File.read(ACTION_PATH)
  unless action.include?("scripts/public-guard.sh")
    findings << "action.yml: does not call scripts/public-guard.sh, so nothing guards the public input"
  end
  calls = action.lines.each_with_index.select { |line, _| line.match?(/^\s*swoosh serve /) }
  findings << "action.yml: no `swoosh serve` invocation found" if calls.empty?
  calls.each do |line, index|
    next if line.match?(/ -- "\$\{SERVICES\[@\]/)
    findings << "action.yml:#{index + 1}: `swoosh serve` takes the services without a `--` separator, " \
                "so a services token that begins with a dash reaches serve as a FLAG"
  end
  unless action.match?(/case "\$THEIA_SERVICES" in/)
    findings << "action.yml: the services input is not checked for a newline, which `read` would truncate " \
                "and $GITHUB_OUTPUT would read as another key=value line"
  end
  if action.match?(/echo "services=\$THEIA_SERVICES"/)
    findings << "action.yml: an output is written as a bare `services=<value>` line; a value with a newline " \
                "appends its own keys, so the multi-line delimiter form is required"
  end
end

# The one dependency the `--` separator rests on: that the binary treats everything after it as data.
# Runs only where a binary is present (CI installs none), so it corroborates the static check above
# rather than replacing it. Never kills anything but the child it spawned.
def check_binary(findings)
  binary = ENV["SWOOSH_BIN"] || ENV["PATH"].to_s.split(File::PATH_SEPARATOR)
                                           .map { |dir| File.join(dir, "swoosh") }
                                           .find { |path| File.executable?(path) }
  return "skipped (no swoosh binary)" unless binary && File.executable?(binary)

  Dir.mktmpdir do |home|
    output, code = run_binary(binary, home, ["serve", "--quiet", "--", "--public-unsafe", "raw"])
    if code.nil? || code.zero?
      findings << "#{binary}: `serve -- --public-unsafe raw` did not refuse (exit #{code.inspect}): the `--` " \
                  "separator no longer makes a dash-leading services token data"
    elsif !output.include?("names no service")
      findings << "#{binary}: `serve -- --public-unsafe raw` refused, but not as an unknown service: #{output.strip}"
    end
  end
  "ran against #{binary}"
end

def run_binary(binary, home, args)
  Open3.popen2e({ "SWOOSH_HOME" => home, "RUST_LOG" => "error" }, binary, *args) do |stdin, out, wait|
    stdin.close
    # A regression here could BIND a node instead of failing, so bound the wait and kill this exact pid.
    watchdog = Thread.new do
      sleep 20
      begin
        Process.kill("KILL", wait.pid)
      rescue Errno::ESRCH
        nil
      end
    end
    output = out.read
    status = wait.value
    watchdog.kill
    [output, status.exitstatus]
  end
end

def main
  findings = []
  check_syntax(findings)
  check_step(findings)
  binary = check_binary(findings)
  CASES.each { |kase| check(kase, findings) } if findings.empty?

  if findings.empty?
    accepted = CASES.count { |kase| kase.verdict == :accept }
    puts "public guard: #{accepted} accepted, #{CASES.size - accepted} refused, as specified; " \
         "action.yml shape checked; live binary #{binary}"
  else
    findings.each { |finding| warn finding }
    exit 1
  end
end

main
