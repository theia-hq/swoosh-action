#!/usr/bin/env ruby
# frozen_string_literal: true

# Check the caller-facing examples against the Action they call.
#
# Two drifts this catches:
#   1. a `with:` key in a README yaml block (or an examples/*.yml file, if one is ever added) that
#      action.yml does not declare;
#   2. a `uses: theia-hq/swoosh-action@<ref>` naming a tag or branch that does not exist upstream;
#   3. a `${{ ... }}` expression substituted into a `run:` script, which a caller would copy into their
#      own workflow (the value is pasted into the shell before it runs; `env:` is the way to read one).
#
# Source of truth for inputs: the `inputs:` keys in action.yml.
# Snippets checked: every ```yaml fenced block in README.md, plus examples/*.yml when present
# (unexercised example files do not ship; the scan stays for their absence).
# The ref check needs the network (`git ls-remote` against the public action repo).
#
# Run: ruby scripts/validate-examples.rb

require "open3"
require "yaml"

ROOT = File.expand_path("..", __dir__)
ACTION_PATH = File.join(ROOT, "action.yml")
README_PATH = File.join(ROOT, "README.md")
EXAMPLE_PATHS = Dir.glob(File.join(ROOT, "examples", "*.yml")).sort
ACTION = "theia-hq/swoosh-action"
REMOTE = "https://github.com/#{ACTION}.git"

Snippet = Struct.new(:path, :text, :line_offset)

# Every fenced yaml block in README.md. `line_offset` maps a snippet line to its line in the file.
def readme_snippets
  snippets = []
  language = nil
  first_line = nil
  body = []
  File.foreach(README_PATH).with_index(1) do |line, number|
    if language
      if line.start_with?("```")
        snippets << Snippet.new("README.md", body.join, first_line - 1) if language.match?(/\Aya?ml\z/)
        language = nil
      else
        body << line
      end
    elsif (fence = line.match(/\A```(\w*)\s*\z/))
      language = fence[1]
      first_line = number + 1
      body = []
    end
  end
  snippets
end

def example_snippets
  EXAMPLE_PATHS.map { |path| Snippet.new(path.delete_prefix("#{ROOT}/"), File.read(path), 0) }
end

def declared_inputs
  action = YAML.safe_load(File.read(ACTION_PATH))
  inputs = action["inputs"]
  abort "action.yml: no `inputs:` mapping" unless inputs.is_a?(Hash)
  inputs.keys
end

def line_of(snippet, node)
  snippet.line_offset + node.start_line + 1
end

def check_with(value, snippet, inputs, findings)
  return unless value.is_a?(Psych::Nodes::Mapping)
  value.children.each_slice(2) do |key, _|
    next unless key.is_a?(Psych::Nodes::Scalar)
    unless inputs.include?(key.value)
      findings << "#{snippet.path}:#{line_of(snippet, key)}: with: key '#{key.value}' is not an input declared in action.yml"
    end
  end
end

def check_uses(value, snippet, line, refs, findings)
  if value == ACTION
    findings << "#{snippet.path}:#{line}: `uses: #{value}` is missing @<ref>"
  elsif value.start_with?("#{ACTION}@")
    ref = value.delete_prefix("#{ACTION}@")
    if ref.empty?
      findings << "#{snippet.path}:#{line}: `uses: #{value}` is missing @<ref>"
    else
      refs[ref] << "#{snippet.path}:#{line}"
    end
  end
end

def check_node(node, snippet, inputs, refs, findings)
  case node
  when Psych::Nodes::Mapping
    node.children.each_slice(2) do |key, value|
      next unless key.is_a?(Psych::Nodes::Scalar)
      case key.value
      when "with"
        check_with(value, snippet, inputs, findings)
      when "uses"
        check_uses(value.value, snippet, line_of(snippet, value), refs, findings) if value.is_a?(Psych::Nodes::Scalar)
      end
      check_node(value, snippet, inputs, refs, findings)
    end
  when Psych::Nodes::Sequence
    node.children.each { |child| check_node(child, snippet, inputs, refs, findings) }
  end
end

# Fallback for blocks that are not YAML documents (an unquoted `: ` inside a value makes Psych refuse
# the block): it still gets its `with:`/`uses:` lines checked, by indentation, so a bad key cannot hide.
def check_lines(snippet, inputs, refs, findings)
  with_indent = nil
  snippet.text.each_line.with_index(1) do |line, number|
    location = snippet.line_offset + number
    if with_indent
      next if line.match?(/\A\s*#/) || line.strip.empty?
      if (key = line.match(/\A(\s+)([A-Za-z0-9_-]+):/)) && key[1].length > with_indent
        name = key[2]
        findings << "#{snippet.path}:#{location}: with: key '#{name}' is not an input declared in action.yml" unless inputs.include?(name)
        next
      end
      with_indent = nil
    end

    with_indent = line[/\A\s*/].length if line.match?(/\A\s*with:\s*(?:#.*)?$/)
    next unless (call = line.match(/\A\s*(?:-\s+)?uses:\s*(.+?)\s*$/))
    value = call[1].sub(/\s+#.*\z/, "")
    value = value[1..-2] if (value.start_with?('"') && value.end_with?('"')) || (value.start_with?("'") && value.end_with?("'"))
    check_uses(value, snippet, location, refs, findings)
  end
end

# A `${{ ... }}` expression inside a `run:` script is pasted into the shell BEFORE it runs, so a value
# carrying a quote or a newline becomes part of the command. The action's own outputs are attacker-shaped
# in exactly that way (a workflow can feed them), and a published example is copied verbatim by callers,
# so no snippet here may teach it: read the value through `env:` and reference the variable instead.
def check_run_expressions(snippet, findings)
  block_indent = nil
  snippet.text.each_line.with_index(1) do |line, number|
    location = snippet.line_offset + number
    if block_indent
      if line.strip.empty? || line[/\A\s*/].length > block_indent
        findings << "#{snippet.path}:#{location}: `${{ ... }}` inside a run: script; pass it through env: and reference the variable" if line.include?("${{")
        next
      end
      block_indent = nil
    end
    next unless (run = line.match(/\A(\s*)(?:-\s+)?run:\s*(.*)$/))

    rest = run[2].strip
    if rest.start_with?("|", ">")
      block_indent = run[1].length
    elsif rest.include?("${{")
      findings << "#{snippet.path}:#{location}: `${{ ... }}` inside a run: script; pass it through env: and reference the variable"
    end
  end
end

def check_snippet(snippet, inputs, refs, findings)
  document = begin
    Psych.parse(snippet.text)
  rescue Psych::SyntaxError
    nil
  end
  if document.is_a?(Psych::Nodes::Document)
    check_node(document.root, snippet, inputs, refs, findings)
  else
    check_lines(snippet, inputs, refs, findings)
  end
end

# A ref exists if it is a tag or a branch. `--exit-code` makes "no match" exit 2; anything else
# nonzero (unreachable remote, bad repo) is a hard error, not a missing ref.
def ls_remote(kind, pattern)
  out, err, status = Open3.capture3(
    { "GIT_TERMINAL_PROMPT" => "0" },
    "git", "ls-remote", "--exit-code", kind, REMOTE, pattern
  )
  code = status.exitstatus
  abort "git ls-remote #{pattern} failed (exit #{code}): #{err.strip}" unless [0, 2].include?(code)
  [out, code]
end

def ref_exists?(ref)
  tags, tag_code = ls_remote("--tags", "refs/tags/#{ref}")
  return true if tag_code.zero? && !tags.empty?
  heads, head_code = ls_remote("--heads", "refs/heads/#{ref}")
  head_code.zero? && !heads.empty?
end

def main
  inputs = declared_inputs
  snippets = example_snippets + readme_snippets
  refs = Hash.new { |hash, ref| hash[ref] = [] }
  findings = []

  snippets.each do |snippet|
    check_snippet(snippet, inputs, refs, findings)
    check_run_expressions(snippet, findings)
  end

  refs.keys.sort.each do |ref|
    next if ref_exists?(ref)
    refs[ref].each do |location|
      findings << "#{location}: `uses: #{ACTION}@#{ref}`: no tag or branch '#{ref}' upstream"
    end
  end

  if findings.empty?
    refs_note = refs.empty? ? "no uses refs" : "refs #{refs.keys.sort.join(', ')} exist"
    puts "checked #{snippets.size} snippet(s) against action.yml: all with: keys are declared inputs, #{refs_note}"
  else
    findings.each { |finding| warn finding }
    exit 1
  end
end

main
