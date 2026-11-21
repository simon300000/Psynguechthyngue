#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "xcodeproj"

ROOT = File.expand_path("..", __dir__)
PROJECT_PATH = File.join(ROOT, "Psynguechthyngue.xcodeproj")
GENERATOR_PATH = File.join(ROOT, "Scripts", "generate-xcodeproj.rb")
SCHEME_RELATIVE_PATH = File.join(
  "xcshareddata",
  "xcschemes",
  "Psynguechthyngue.xcscheme"
)

def canonical_file_reference(reference)
  if reference.respond_to?(:hierarchy_path)
    {
      "class" => reference.class.name.split("::").last,
      "hierarchyPath" => reference.hierarchy_path,
      "name" => reference.respond_to?(:name) ? reference.name : nil,
      "path" => reference.respond_to?(:path) ? reference.path : nil,
      "sourceTree" => reference.respond_to?(:source_tree) ? reference.source_tree : nil,
    }
  elsif reference.respond_to?(:product_name)
    {
      "class" => reference.class.name.split("::").last,
      "productName" => reference.product_name,
    }
  else
    {
      "class" => reference.class.name.split("::").last,
      "displayName" => reference.respond_to?(:display_name) ? reference.display_name : nil,
    }
  end
end

def canonical_build_file(build_file)
  reference = build_file.file_ref
  reference ||= build_file.product_ref if build_file.respond_to?(:product_ref)

  {
    "reference" => reference.nil? ? nil : canonical_file_reference(reference),
    "settings" => build_file.settings,
  }
end

def canonical_build_configuration(configuration)
  {
    "name" => configuration.name,
    "baseConfiguration" => if configuration.base_configuration_reference
      canonical_file_reference(configuration.base_configuration_reference)
    end,
    "buildSettings" => configuration.build_settings.sort.to_h,
  }
end

def canonical_project(project_path)
  project = Xcodeproj::Project.open(project_path)

  groups = project.groups.map do |group|
    {
      "class" => group.class.name.split("::").last,
      "hierarchyPath" => group.hierarchy_path,
      "name" => group.name,
      "path" => group.path,
      "sourceTree" => group.source_tree,
    }
  end.sort_by { |group| JSON.generate(group) }

  variant_groups = project.objects_by_uuid.values
    .grep(Xcodeproj::Project::Object::PBXVariantGroup)
    .map do |group|
      {
        "hierarchyPath" => group.hierarchy_path,
        "children" => group.children.map { |child| canonical_file_reference(child) }
          .sort_by { |child| JSON.generate(child) },
      }
    end
    .sort_by { |group| JSON.generate(group) }

  files = project.files.map { |file| canonical_file_reference(file) }
    .sort_by { |file| JSON.generate(file) }

  package_references = project.root_object.package_references.map do |reference|
    {
      "class" => reference.class.name.split("::").last,
      "relativePath" => reference.respond_to?(:relative_path) ? reference.relative_path : nil,
      "repositoryURL" => reference.respond_to?(:repository_url) ? reference.repository_url : nil,
      "requirement" => reference.respond_to?(:requirement) ? reference.requirement : nil,
    }
  end.sort_by { |reference| JSON.generate(reference) }

  targets = project.targets.map do |target|
    phases = target.build_phases.each_with_index.map do |phase, phase_index|
      details = {
        "class" => phase.class.name.split("::").last,
        "name" => phase.display_name,
        "order" => phase_index,
        "files" => phase.files.map { |file| canonical_build_file(file) }
          .sort_by { |file| JSON.generate(file) },
      }
      if phase.is_a?(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase)
        details["destinationPath"] = phase.dst_path
        details["destinationSubfolder"] = phase.dst_subfolder_spec
      end
      if phase.is_a?(Xcodeproj::Project::Object::PBXShellScriptBuildPhase)
        details["shellPath"] = phase.shell_path
        details["shellScript"] = phase.shell_script
        details["inputPaths"] = phase.input_paths
        details["outputPaths"] = phase.output_paths
        details["alwaysOutOfDate"] = phase.always_out_of_date
        details["showEnvironmentInLog"] = phase.show_env_vars_in_log
      end
      details
    end.sort_by { |phase| [phase.fetch("class"), phase.fetch("name")] }

    {
      "name" => target.name,
      "productName" => target.product_name,
      "productType" => target.respond_to?(:product_type) ? target.product_type : nil,
      "buildConfigurations" => target.build_configurations
        .map { |configuration| canonical_build_configuration(configuration) }
        .sort_by { |configuration| configuration.fetch("name") },
      "buildPhases" => phases,
      "dependencies" => target.dependencies.map { |dependency| dependency.target&.name }.compact.sort,
      "packageProducts" => if target.respond_to?(:package_product_dependencies)
        target.package_product_dependencies.map(&:product_name).sort
      else
        []
      end,
    }
  end.sort_by { |target| target.fetch("name") }

  {
    "developmentRegion" => project.root_object.development_region,
    "knownRegions" => project.root_object.known_regions,
    "projectBuildConfigurations" => project.build_configurations
      .map { |configuration| canonical_build_configuration(configuration) }
      .sort_by { |configuration| configuration.fetch("name") },
    "groups" => groups,
    "variantGroups" => variant_groups,
    "fileReferences" => files,
    "packageReferences" => package_references,
    "targets" => targets,
  }
end

def canonical_scheme(project_path)
  scheme_path = File.join(project_path, SCHEME_RELATIVE_PATH)
  File.readlines(scheme_path, chomp: true).map do |line|
    line.gsub(/BlueprintIdentifier = "[A-F0-9]+"/, 'BlueprintIdentifier = "<UUID>"')
  end
end

def write_diff(current_snapshot, generated_snapshot, directory)
  current_path = File.join(directory, "current-membership.json")
  generated_path = File.join(directory, "generated-membership.json")
  File.write(current_path, JSON.pretty_generate(current_snapshot) + "\n")
  File.write(generated_path, JSON.pretty_generate(generated_snapshot) + "\n")
  output, = Open3.capture2e("diff", "-u", current_path, generated_path)
  warn output
end

Dir.mktmpdir("psy-xcode-membership-") do |directory|
  generated_project_path = File.join(directory, "Psynguechthyngue.xcodeproj")
  environment = { "PSY_XCODEPROJ_PATH" => generated_project_path }
  output, status = Open3.capture2e(environment, RbConfig.ruby, GENERATOR_PATH)
  abort("project generator failed:\n#{output}") unless status.success?

  current_snapshot = canonical_project(PROJECT_PATH)
  generated_snapshot = canonical_project(generated_project_path)
  current_snapshot["sharedScheme"] = canonical_scheme(PROJECT_PATH)
  generated_snapshot["sharedScheme"] = canonical_scheme(generated_project_path)

  unless current_snapshot == generated_snapshot
    warn "error: committed Xcode project membership differs from Scripts/generate-xcodeproj.rb"
    write_diff(current_snapshot, generated_snapshot, directory)
    exit 1
  end

  counts = current_snapshot.fetch("targets").to_h do |target|
    member_count = target.fetch("buildPhases").sum { |phase| phase.fetch("files").length }
    [target.fetch("name"), member_count]
  end
  puts "Generator-authoritative Xcode membership passed: #{counts.sort.to_h}."
end
