#!/usr/bin/env ruby
# frozen_string_literal: true

# Check catalogue metadata against the committed spec contracts without
# requiring a package install. This checks identity and coverage references;
# it does not turn partial implementation into accepted evidence.

require "yaml"

root = File.expand_path("..", __dir__)
spec_directory = File.join(root, "docs", "specs")
catalogue = YAML.safe_load(File.read(File.join(spec_directory, "catalogue.yaml")))
contracts = catalogue.fetch("contracts")
external = catalogue.fetch("external_contracts")
failures = []

ids = contracts.map { |contract| contract.fetch("id") }
failures << "duplicate contract IDs" unless ids.uniq == ids

contracts.each do |contract|
  id = contract.fetch("id")
  filename = contract.fetch("file")
  path = File.expand_path(filename, spec_directory)
  unless path.start_with?(spec_directory + File::SEPARATOR) && File.file?(path)
    failures << "#{id}: missing spec file #{filename}"
    next
  end

  body = File.read(path)
  heading = body.lines.first&.strip
  failures << "#{id}: heading does not match catalogue" unless heading&.start_with?("# #{id} ")

  declared_version = body[/^Version: (\d+\.\d+\.\d+)\./, 1]
  if declared_version != contract.fetch("version")
    failures << "#{id}: catalogue #{contract.fetch('version')} != file #{declared_version || 'missing'}"
  end

  cases = contract.fetch("required_cases")
  failures << "#{id}: duplicate required cases" unless cases.uniq == cases
  cases.each do |required_case|
    failures << "#{id}: #{required_case} absent from spec" unless body.include?(required_case)
  end

  unless %w[planned partial complete].include?(contract.fetch("implementation_status"))
    failures << "#{id}: unknown implementation status"
  end
  unless %w[missing partial complete].include?(contract.fetch("evidence_status"))
    failures << "#{id}: unknown evidence status"
  end

  contract.fetch("requires").each do |dependency|
    next if ids.include?(dependency) || external.key?(dependency)

    failures << "#{id}: unknown dependency #{dependency}"
  end
end

by_id = contracts.to_h { |contract| [contract.fetch("id"), contract] }
visited = {}
visit = lambda do |id, path|
  if visited[id] == :visiting
    failures << "dependency cycle: #{(path + [id]).join(' -> ')}"
    next
  end
  next if visited[id] == :done

  visited[id] = :visiting
  by_id.fetch(id).fetch("requires").each do |dependency|
    visit.call(dependency, path + [id]) if by_id.key?(dependency)
  end
  visited[id] = :done
end
ids.each { |id| visit.call(id, []) }

if failures.empty?
  puts "#{contracts.length} spec contracts match catalogue identity, versions, cases and dependencies"
else
  warn failures.join("\n")
  exit 1
end
