#!/usr/bin/env ruby
# frozen_string_literal: true

# Exercise the action's own decisions by RUNNING them. The action is a wrapper: it installs a pinned
# binary, adopts an invite or self-roots, calls `swoosh serve`, and emits two outputs. Everything about a
# service, a target, or a public name belongs to swoosh and is proven at `serve` before the node is
# announced, so nothing here re-checks it. What is left is the handful of rules the action alone can make,
# because they happen before swoosh exists or concern files swoosh does not write.
#
# The step bodies live in `run:` blocks, so the test extracts each block from action.yml and executes it
# against a stub `swoosh` on PATH and scratch $GITHUB_OUTPUT / $GITHUB_ENV files, then asserts what the
# stub actually received and what was actually written. Nothing here matches on the step's TEXT: a rule
# proved by substring is a rule that survives being rewritten in another spelling, or gutted to `:`, with
# the test still green.
#
# Run: ruby scripts/test-steps.rb

require "open3"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("..", __dir__)
ACTION_PATH = File.join(ROOT, "action.yml")
# One token per argv word, joined by a byte no service entry can hold, so the stub's record of what serve
# received survives spaces and quoting intact.
ARGV_SEPARATOR = "\u001F"
INSTALL_STEP = 0
NODE_STEP = 1

# The action's own `services` default: what the node serves when a caller sets only `public`.
DEFAULT = ["ssh=sshd:", "ping=ping:", "speed=speed:"].freeze

Result = Struct.new(:code, :log, :outputs, :environment, :invocations)

def step_body(index)
  YAML.safe_load(File.read(ACTION_PATH))["runs"]["steps"][index]["run"]
end

# `swoosh`, replaced by a recorder. `serve` holds the process open so the step's liveness check passes,
# unless `--expires` puts serve in the foreground, where the real binary returns when the node ends, or
# `SWOOSH_SERVE_FAIL` makes it die at startup the way a bad gate or a taken port would.
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
        if [ -n "${SWOOSH_SERVE_FAIL:-}" ]; then
          echo "bf01deadbeefcafe failed to bind" >&2
          exit 7
        fi
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
    "THEIA_PUBLIC" => "", "EXPIRES" => "", "GH_TOKEN" => "token", "SWOOSH_REF" => "latest",
    "SWOOSH_SERVE_FAIL" => "", "RELAY" => "", "RESOLVER" => ""
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

def check_syntax(findings)
  [INSTALL_STEP, NODE_STEP].each do |index|
    Dir.mktmpdir do |work|
      script = File.join(work, "step.sh")
      File.write(script, step_body(index))
      _, error, status = Open3.capture3("bash", "-n", script)
      findings << "action.yml step #{index}: does not parse: #{error.strip}" unless status.success?
    end
  end
end

# The paths that DO something: what serve received, and what reached the two runner files.
def check_step_runs(findings)
  Dir.mktmpdir do |work|
    install_stub(work)
    body = step_body(NODE_STEP)
    delimiters = []

    # The whole path, with a public list that passes through to serve as ONE argv (serve splits on the
    # commas and proves each name itself).
    happy = run_step(work, body, "THEIA_SERVICES" => DEFAULT.join(" "), "THEIA_PUBLIC" => "ping,speed")
    where = "step(services default, public ping,speed)"
    findings << "#{where}: exited #{happy.code}: #{happy.log}" unless happy.code.zero?
    delimiters << check_written(happy, "node-id", "bf01deadbeefcafe", where, findings)
    delimiters << check_written(happy, "services", DEFAULT.join(" "), where, findings)
    check_serve_argv(happy, DEFAULT, ["--public", "ping,speed"], where, findings)

    # The action no longer narrows the public set: a forward the operator named is their own informed
    # choice, delivered verbatim, and the node rules on it at startup. This row is the reversal.
    forward = run_step(work, body, "THEIA_SERVICES" => "web=127.0.0.1:8080", "THEIA_PUBLIC" => "web")
    where = "step(a public forward)"
    findings << "#{where}: exited #{forward.code}: #{forward.log}" unless forward.code.zero?
    check_serve_argv(forward, ["web=127.0.0.1:8080"], ["--public", "web"], where, findings)

    # A services token that begins with a dash must arrive as DATA, whatever the call looks like.
    smuggle = ["raw=file:/etc/passwd", "--public-unsafe", "raw"]
    dashed = run_step(work, body, "THEIA_SERVICES" => smuggle.join(" "))
    check_serve_argv(dashed, smuggle, [], "step(a dash-leading services token)", findings)

    # A folded yaml block (`>`) collapses to one line and keeps a trailing newline: it is the same list a
    # `>-` writes, so it serves, and the trimmed value is what is written out.
    folded = run_step(work, body, "THEIA_SERVICES" => "ping=ping: speed=speed:\n")
    where = "step(a folded yaml block)"
    findings << "#{where}: exited #{folded.code}: #{folded.log}" unless folded.code.zero?
    check_serve_argv(folded, ["ping=ping:", "speed=speed:"], [], where, findings)
    delimiters << check_written(folded, "services", "ping=ping: speed=speed:", where, findings)

    # The two reach inputs pass through as their own flags, each as ONE argv, and an empty one adds
    # nothing: a `--relay ""` would be a flag the node has to rule on rather than the default it already
    # has. The values are opaque to this action by ruling, so they arrive verbatim and swoosh refuses a bad
    # one; a URL that begins with a dash must therefore still arrive as DATA, never as a flag.
    reach = run_step(work, body, "THEIA_SERVICES" => "ping=ping:",
                     "RELAY" => "https://relay.example", "RESOLVER" => "https://dns.example/pkarr")
    where = "step(relay and resolver)"
    findings << "#{where}: exited #{reach.code}: #{reach.log}" unless reach.code.zero?
    check_serve_argv(reach, ["ping=ping:"],
                     ["--relay", "https://relay.example", "--resolver", "https://dns.example/pkarr"],
                     where, findings)

    # Only one named: the other stays n0's, which is serve's own default and takes no flag.
    relay_only = run_step(work, body, "THEIA_SERVICES" => "ping=ping:", "RELAY" => "https://relay.example")
    where = "step(relay only)"
    findings << "#{where}: exited #{relay_only.code}: #{relay_only.log}" unless relay_only.code.zero?
    check_serve_argv(relay_only, ["ping=ping:"], ["--relay", "https://relay.example"], where, findings)
    if relay_only.log.include?("--resolver")
      findings << "#{where}: an unset resolver still reached serve's argv: #{relay_only.log}"
    end

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

    # A node that died at startup: the step fails with serve's own code, and NOTHING is published. An
    # output settled before the liveness check would name a node no peer can reach, and the echoed stderr
    # is the one place the node's key could reach a public log, so it goes through the redaction.
    died = run_step(work, body, "THEIA_SERVICES" => "ping=ping:", "SWOOSH_SERVE_FAIL" => "1")
    where = "step(serve dies at startup)"
    findings << "#{where}: expected serve's own exit 7, got #{died.code}: #{died.log}" unless died.code == 7
    findings << "#{where}: failed, but wrote #{died.outputs.keys.inspect}" unless died.outputs.empty?
    findings << "#{where}: echoed the node's key unredacted: #{died.log}" if died.log.include?("bf01deadbeefcafe")
    findings << "#{where}: did not echo serve's stderr: #{died.log}" unless died.log.include?("bf01<redacted>")

    # One delimiter per write, drawn fresh: a pinned one is a fence an input can close.
    drawn = delimiters.compact
    findings << "the delimiter is not drawn per write: #{drawn.inspect}" unless drawn.uniq.size == drawn.size

    check_refusals(work, findings)
  end
end

# The three refusals the action still makes, and the only three: each fires before anything runs, exits 1,
# says why exactly once, serves nothing, and writes nothing to either runner file.
def check_refusals(work, findings)
  body = step_body(NODE_STEP)
  refusals = {
    # A literal yaml block (`|`) keeps its interior newlines, and `read` stops at the first one: line two
    # onward would be dropped silently, and the value is written to $GITHUB_OUTPUT besides.
    "a multi-line services list" => { "THEIA_SERVICES" => "ping=ping:\nnode-id=bf01ATTACKER" },
    # `expires` is echoed back by serve's own parse error, and the failure path re-emits that stderr into
    # the public log, so the shape is proven here instead.
    "a workflow command in expires" => { "THEIA_SERVICES" => "ping=ping:", "EXPIRES" => "30m\n::error::FORGED" },
    "a duration with no unit" => { "THEIA_SERVICES" => "ping=ping:", "EXPIRES" => "30" }
  }
  refusals.each do |why, inputs|
    result = run_step(work, body, inputs)
    where = "step(#{why})"
    findings << "#{where}: expected a refusal (exit 1), got #{result.code}: #{result.log}" unless result.code == 1
    findings << "#{where}: refused, but served anyway: #{serve_argv(result).inspect}" unless serve_argv(result).empty?
    findings << "#{where}: refused, but wrote #{result.outputs.keys.inspect}" unless result.outputs.empty?
    findings << "#{where}: refused, but wrote #{result.environment.keys.inspect} into the job environment" unless result.environment.empty?
    emitted = commands(result.log)
    findings << "#{where}: emitted #{emitted.size} workflow commands, not one refusal: #{emitted.inspect}" unless emitted.size == 1
  end

  # The install step's own refusal. `version` is concatenated into a download URL before any binary
  # exists, so its shape is proven first; the refusal must not reprint the value, or the payload rides the
  # refusal into a log that honours `::` lines.
  payload = "v1\n::stop-commands::hax\n::notice::pwned"
  install = run_step(work, step_body(INSTALL_STEP), "SWOOSH_REF" => payload)
  where = "step(a workflow command in version)"
  findings << "#{where}: expected a refusal (exit 1), got #{install.code}: #{install.log}" unless install.code == 1
  emitted = commands(install.log)
  findings << "#{where}: emitted #{emitted.size} workflow commands, not one refusal: #{emitted.inspect}" unless emitted.size == 1
  leaked = payload.lines.map(&:chomp).reject(&:empty?).select { |part| install.log.include?(part) }
  findings << "#{where}: the refusal reprinted #{leaked.inspect} from the rejected value" unless leaked.empty?
end

# The one dependency the `--` separator rests on: that the binary treats everything after it as data.
# Runs only where a binary is present (CI installs none), so it corroborates the argv check above rather
# than replacing it. Never kills anything but the child it spawned.
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
  check_step_runs(findings) if findings.empty?
  binary = check_binary(findings)

  if findings.empty?
    puts "the action's steps ran 11 scenarios (7 ran, 4 refused); live binary #{binary}"
  else
    findings.each { |finding| warn finding }
    exit 1
  end
end

main
