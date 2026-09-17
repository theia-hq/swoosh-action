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
# The step that CALLS the guard is exercised the same way, by running it. Its decisions live in a `run:`
# block, so the test extracts that block from action.yml and executes it against a stub `swoosh` on PATH
# and a scratch $GITHUB_OUTPUT, then asserts what the stub actually received and what was actually
# written. Nothing here matches on the step's TEXT: a rule proved by substring is a rule that survives
# being rewritten in another spelling, or gutted to `:`, with the test still green.
#
# Run: ruby scripts/test-public-guard.rb

require "open3"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("..", __dir__)
GUARD = File.join(ROOT, "scripts", "public-guard.sh")
ACTION_PATH = File.join(ROOT, "action.yml")
# One token per argv word, joined by a byte no service entry can hold, so the stub's record of what serve
# received survives spaces and quoting intact.
ARGV_SEPARATOR = "\u001F"

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

  # Refused in every spelling a URL parser decodes, not just the one a person would write: an octal octet,
  # a bare integer, hex, a trailing dot, an IPv4 embedded in a v6 literal, and the expanded loopback.
  Case.new(:refuse, "an octal octet", "fetch", ["fetch=fetch:http://0177.0.0.1:22"]),
  Case.new(:refuse, "a leading zero", "fetch", ["fetch=fetch:http://010.0.0.5/"]),
  Case.new(:refuse, "loopback as one integer", "fetch", ["fetch=fetch:http://2130706433/"]),
  Case.new(:refuse, "loopback in hex", "fetch", ["fetch=fetch:http://0x7f000001/"]),
  Case.new(:refuse, "a rooted localhost", "fetch", ["fetch=fetch:http://localhost./"]),
  Case.new(:refuse, "an IPv4-mapped literal", "fetch", ["fetch=fetch:http://[::ffff:127.0.0.1]/"]),
  Case.new(:refuse, "loopback written out", "fetch", ["fetch=fetch:http://[0:0:0:0:0:0:0:1]/"]),
  Case.new(:refuse, "the metadata address behind NAT64", "fetch", ["fetch=fetch:http://[64:ff9b::169.254.169.254]/"]),
  Case.new(:refuse, "the top of fe80::/10", "fetch", ["fetch=fetch:http://[febf::1]/"]),
  Case.new(:refuse, "the unspecified address", "fetch", ["fetch=fetch:http://[::]/"]),
  Case.new(:accept, "a public IPv4 literal", "fetch", ["fetch=fetch:https://1.1.1.1"]),
  Case.new(:accept, "a public IPv6 literal", "fetch", ["fetch=fetch:http://[2606:4700::1111]/"]),
  Case.new(:accept, "1:: is not ::1", "fetch", ["fetch=fetch:http://[1::]/"]),

  # Refused: an empty token. `read -ra` drops a trailing empty field where serve's parser keeps it, so the
  # guard would prove one name and serve would receive two.
  Case.new(:refuse, "a trailing comma", "ping,", DEFAULT),
  Case.new(:refuse, "a leading comma", ",ping", DEFAULT),
  Case.new(:refuse, "a doubled comma", "ping,,speed", DEFAULT),

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

# The step body, run for real. Each scenario gets a fresh scratch dir holding the stub `swoosh`, the argv
# record, and the files the runner would provide, so a scenario reads only its own evidence.
Result = Struct.new(:code, :log, :outputs, :environment, :invocations)

def step_body(index)
  steps = YAML.safe_load(File.read(ACTION_PATH))["runs"]["steps"]
  steps[index]["run"]
end

# `swoosh`, replaced by a recorder. `serve` holds the process open so the step's liveness check passes,
# unless `--expires` puts serve in the foreground, where the real binary returns when the node ends.
def install_stub(work)
  bin = File.join(work, "bin")
  Dir.mkdir(bin)
  path = File.join(bin, "swoosh")
  File.write(path, <<~STUB)
    #!/usr/bin/env bash
    printf '%s\\037' "$@" >> "$SWOOSH_ARGV_LOG"
    printf '\\n' >> "$SWOOSH_ARGV_LOG"
    case "$1" in
      identity) echo bf01deadbeefcafe ;;
      adopt) cat > /dev/null ;;
      serve)
        printf '%s' "$$" > "$SWOOSH_SERVE_PID"
        case " $* " in *" --expires "*) exit 0 ;; esac
        sleep 30
        ;;
    esac
  STUB
  File.chmod(0o755, path)
  bin
end

def run_step(work, body, inputs)
  scratch = Dir.mktmpdir("scenario", work)
  paths = %w[log out env argv pid].to_h { |name| [name.to_sym, File.join(scratch, name)] }
  script = File.join(scratch, "step.sh")
  File.write(script, body)
  environment = {
    "PATH" => "#{File.join(work, 'bin')}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH', '')}",
    "GITHUB_ACTION_PATH" => ROOT, "RUNNER_TEMP" => scratch,
    "GITHUB_OUTPUT" => paths[:out], "GITHUB_ENV" => paths[:env],
    "SWOOSH_ARGV_LOG" => paths[:argv], "SWOOSH_SERVE_PID" => paths[:pid],
    "RUNNER_ENVIRONMENT" => "github-hosted", "SWOOSH_INVITE" => "invite", "THEIA_SERVICES" => "",
    "THEIA_PUBLIC" => "", "EXPIRES" => "", "GH_TOKEN" => "token", "SWOOSH_REF" => "latest"
  }.merge(inputs)
  [paths[:out], paths[:env], paths[:argv]].each { |file| File.write(file, "") }

  pid = Process.spawn(environment, "bash", script, out: paths[:log], err: %i[child out])
  _, status = Process.wait2(pid)
  # A backgrounded stub serve outlives the step. Kill the ONE pid it recorded, never by name: another
  # agent or the founder may be running the real binary on this machine.
  if File.size?(paths[:pid])
    begin
      Process.kill("KILL", File.read(paths[:pid]).to_i)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
  end
  invocations = File.read(paths[:argv]).lines.map { |line| line.chomp.split(ARGV_SEPARATOR, -1)[0..-2] }
  Result.new(status.exitstatus, File.read(paths[:log]), parse_kv(paths[:out]), parse_kv(paths[:env]), invocations)
end

# Read a runner file the way the runner does: `key=value` lines, plus the multi-line `key<<delimiter`
# form. A `nil` delimiter records that the value was written UNFENCED, which is the finding.
def parse_kv(path)
  pairs = {}
  lines = File.read(path).lines.map(&:chomp)
  index = 0
  while index < lines.size
    line = lines[index]
    index += 1
    if (fenced = line.match(/\A([^=<]+)<<(.+)\z/))
      body = []
      while index < lines.size && lines[index] != fenced[2]
        body << lines[index]
        index += 1
      end
      index += 1
      pairs[fenced[1]] = { value: body.join("\n"), delimiter: fenced[2] }
    else
      key, _, value = line.partition("=")
      pairs[key] = { value: value, delimiter: nil }
    end
  end
  pairs
end

def serve_argv(result)
  result.invocations.select { |argv| argv.first == "serve" }
end

# A written value is safe only if it went inside a block whose delimiter is unguessable and drawn per
# write: a constant (or a small random) delimiter is a value an input can close.
def check_written(result, key, expected, where, findings)
  written = result.outputs[key] || result.environment[key]
  return findings << "#{where}: nothing wrote `#{key}`" if written.nil?

  findings << "#{where}: `#{key}` was written unfenced, so a value with a line break appends its own keys" if written[:delimiter].nil?
  unless written[:delimiter].nil? || written[:delimiter].match?(/\Agha_[0-9a-f]{32}\z/)
    findings << "#{where}: `#{key}` was fenced with #{written[:delimiter].inspect}, not 16 fresh urandom bytes"
  end
  findings << "#{where}: `#{key}` is #{written[:value].inspect}, expected #{expected.inspect}" unless written[:value] == expected
  written[:delimiter]
end

# Every `::` line the runner would honour as a workflow command.
def commands(log)
  log.lines.map(&:chomp).select { |line| line.start_with?("::") }
end

def check_step_runs(findings)
  Dir.mktmpdir do |work|
    install_stub(work)
    body = step_body(1)
    delimiters = []

    # The whole path, with a public list the guard must prove and then pass through.
    happy = run_step(work, body, "THEIA_SERVICES" => DEFAULT.join(" "), "THEIA_PUBLIC" => "ping,speed")
    where = "step(services default, public ping,speed)"
    findings << "#{where}: exited #{happy.code}: #{happy.log}" unless happy.code.zero?
    delimiters << check_written(happy, "node-id", "bf01deadbeefcafe", where, findings)
    delimiters << check_written(happy, "services", DEFAULT.join(" "), where, findings)
    check_serve_argv(happy, DEFAULT, ["--public", "ping,speed"], where, findings)

    # A services token that begins with a dash must arrive as DATA, whatever the call looks like.
    smuggle = ["raw=file:/etc/passwd", "--public-unsafe", "raw"]
    dashed = run_step(work, body, "THEIA_SERVICES" => smuggle.join(" "))
    check_serve_argv(dashed, smuggle, [], "step(a dash-leading services token)", findings)

    # `expires` runs serve in the foreground, and settles the outputs on its own path.
    timed = run_step(work, body, "THEIA_SERVICES" => "ping=ping:", "EXPIRES" => "10m")
    where = "step(expires 10m)"
    findings << "#{where}: exited #{timed.code}: #{timed.log}" unless timed.code.zero?
    delimiters << check_written(timed, "services", "ping=ping:", where, findings)
    check_serve_argv(timed, ["ping=ping:"], ["--expires", "10m"], where, findings)

    # Self-rooted: no invite, so the step exports the fresh home through the other line-oriented file.
    rooted = run_step(work, body, "THEIA_SERVICES" => "ping=ping:", "SWOOSH_INVITE" => "")
    where = "step(self-rooted)"
    findings << "#{where}: exited #{rooted.code}: #{rooted.log}" unless rooted.code.zero?
    home = rooted.environment["SWOOSH_HOME"]
    if home.nil?
      findings << "#{where}: nothing exported SWOOSH_HOME"
    else
      findings << "#{where}: SWOOSH_HOME was written unfenced into $GITHUB_ENV" if home[:delimiter].nil?
      delimiters << home[:delimiter]
    end

    # One delimiter per write, drawn fresh: a pinned one is a fence an input can close.
    drawn = delimiters.compact
    findings << "the delimiter is not drawn per write: #{drawn.inspect}" unless drawn.uniq.size == drawn.size

    check_refusals(work, body, findings)
  end
end

# Every refusal: the step must exit 1, say why once, serve nothing, and write nothing.
def check_refusals(work, body, findings)
  refusals = {
    "a newline in services" => { "THEIA_SERVICES" => "ping=ping:\nnode-id=bf01ATTACKER" },
    "a public name bound to a forward" => { "THEIA_SERVICES" => "ping=ping:80", "THEIA_PUBLIC" => "ping" },
    "a public name that is not served" => { "THEIA_SERVICES" => "ssh=sshd:", "THEIA_PUBLIC" => "ping" },
    "a workflow command in expires" => { "THEIA_SERVICES" => "ping=ping:", "EXPIRES" => "30m\n::error::FORGED" }
  }
  refusals.each do |why, inputs|
    result = run_step(work, body, inputs)
    where = "step(#{why})"
    findings << "#{where}: expected a refusal (exit 1), got #{result.code}: #{result.log}" unless result.code == 1
    findings << "#{where}: refused, but served anyway: #{serve_argv(result).inspect}" unless serve_argv(result).empty?
    findings << "#{where}: refused, but wrote #{result.outputs.keys.inspect}" unless result.outputs.empty?
    emitted = commands(result.log)
    findings << "#{where}: emitted #{emitted.size} workflow commands, not one refusal: #{emitted.inspect}" unless emitted.size == 1
  end

  # The install step's own refusal, which reprints the value it rejected.
  install = run_step(work, step_body(0), "SWOOSH_REF" => "v1\n::stop-commands::hax\n::notice::pwned")
  where = "step(a workflow command in version)"
  findings << "#{where}: expected a refusal (exit 1), got #{install.code}: #{install.log}" unless install.code == 1
  emitted = commands(install.log)
  findings << "#{where}: emitted #{emitted.size} workflow commands, not one refusal: #{emitted.inspect}" unless emitted.size == 1
end

# What serve RECEIVED: every service entry as a positional after `--`, and no service word before it.
def check_serve_argv(result, services, flags, where, findings)
  calls = serve_argv(result)
  # Exactly one: a second call, however it is spelled (`timeout 3600 swoosh serve ...`), is a second argv
  # nothing above proved.
  return findings << "#{where}: serve was called #{calls.size} times, expected once: #{calls.inspect}" unless calls.size == 1

  argv = calls.first
  separator = argv.index("--")
  return findings << "#{where}: serve got #{argv.inspect} with no `--`, so a dash-leading services token is a FLAG" if separator.nil?

  findings << "#{where}: serve got #{argv[(separator + 1)..].inspect} after `--`, expected #{services.inspect}" unless argv[(separator + 1)..] == services
  before = argv[1...separator]
  findings << "#{where}: serve got #{before.inspect} before `--`, expected #{(['--quiet'] + flags).inspect}" unless before == ["--quiet"] + flags
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
  CASES.each { |kase| check(kase, findings) }
  check_step_runs(findings) if findings.empty?
  binary = check_binary(findings)

  if findings.empty?
    accepted = CASES.count { |kase| kase.verdict == :accept }
    puts "public guard: #{accepted} accepted, #{CASES.size - accepted} refused, as specified; " \
         "the step ran 9 scenarios; live binary #{binary}"
  else
    findings.each { |finding| warn finding }
    exit 1
  end
end

main
