#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Generates Psynguechthyngue.xcodeproj (DESIGN.md §11 WP-E). Deterministic:
# object IDs are derived from the project structure, so regenerating without
# source changes produces no diff.
#
#   Psynguechthyngue          App/** + Platform/PsyBridgeAdapter.swift
#                             + PsySync (local package) + PsyBridge.xcframework
#   PsyFileProvider           FileProvider/** + Platform/PsyBridgeAdapter.swift
#                             + PsySync + PsyBridge.xcframework
#   PsynguechthyngueUITests   Tests/PsynguechthyngueUITests/**
#   PsyBridgeBootstrap        Scripts/bootstrap.sh (builds the xcframework when stale)
#
# Tools/** (dev harnesses) is intentionally not part of the project.
#
# Usage: ruby Scripts/generate-xcodeproj.rb   (overwrites the project)

require "digest"
require "fileutils"
require "xcodeproj"

# Deterministic object IDs: the script creates objects in a fixed order, so a
# counter-derived ID is stable across runs (xcodeproj's random IDs are not, and
# its predictabilize_uuids collides on the two identically shaped targets).
module PsyDeterministicUUIDs
  def generate_uuid
    @psy_uuid_counter = (@psy_uuid_counter || 0) + 1
    Digest::SHA256.hexdigest("psynguechthyngue-#{@psy_uuid_counter}")[0, 24].upcase
  end
end
Xcodeproj::Project.prepend(PsyDeterministicUUIDs)

ROOT = File.expand_path("..", __dir__)
PROJECT_PATH = File.expand_path(
  ENV.fetch("PSY_XCODEPROJ_PATH", File.join(ROOT, "Psynguechthyngue.xcodeproj")), ROOT
)
DEPLOYMENT_TARGET = "26.0"
XCFRAMEWORK = "Artifacts/PsyBridge.xcframework"

FileUtils.rm_rf(PROJECT_PATH)
project = Xcodeproj::Project.new(PROJECT_PATH)
project.root_object.development_region = "en"
project.root_object.known_regions = %w[en zh-Hans Base]

main = project.main_group
config_group = main.new_group("Config", "Config")
base_config = config_group.new_file("Base.xcconfig")
%w[CI.xcconfig UITests.xcconfig Local.xcconfig.example].each { |f| config_group.new_file(f) }

def swift_sources(dir)
  Dir.glob(File.join(ROOT, dir, "**", "*.swift")).sort.map { |p| p.delete_prefix("#{ROOT}/#{dir}/") }
end

def add_sources(group, dir, target)
  swift_sources(dir).each do |relative|
    *dirs, _name = relative.split("/")
    sub = dirs.reduce(group) { |g, d| g.children.find { |c| c.display_name == d && c.isa == "PBXGroup" } || g.new_group(d, d) }
    target.add_file_references([sub.new_file(File.basename(relative))])
  end
end

app = project.new_target(:application, "Psynguechthyngue", :ios, DEPLOYMENT_TARGET)
provider = project.new_target(:app_extension, "PsyFileProvider", :ios, DEPLOYMENT_TARGET)
ui_tests = project.new_target(:ui_test_bundle, "PsynguechthyngueUITests", :ios, DEPLOYMENT_TARGET)

# --- PsyBridge.xcframework (built by GoBridge/Scripts/build-xcframework.sh) ---
bootstrap = project.new_aggregate_target("PsyBridgeBootstrap")
phase = bootstrap.new_shell_script_build_phase("Build PsyBridge.xcframework if stale")
phase.shell_path = "/bin/bash"
phase.shell_script = 'exec /bin/bash "${SRCROOT}/Scripts/bootstrap.sh"'
phase.output_paths = ["$(SRCROOT)/#{XCFRAMEWORK}"]
phase.always_out_of_date = "1"
phase.show_env_vars_in_log = "0"
bootstrap.build_configurations.each { |c| c.build_settings["ENABLE_USER_SCRIPT_SANDBOXING"] = "NO" }

# PsyBridge is linked through search paths, not an XCFramework file reference:
# Xcode validates referenced XCFrameworks while *planning* the build, before
# PsyBridgeBootstrap could create the (git-ignored) artifact on a fresh checkout.
PSYBRIDGE_LINK_SETTINGS = {
  "FRAMEWORK_SEARCH_PATHS[sdk=iphoneos*]" => "$(inherited) $(SRCROOT)/#{XCFRAMEWORK}/ios-arm64",
  "FRAMEWORK_SEARCH_PATHS[sdk=iphonesimulator*]" => "$(inherited) $(SRCROOT)/#{XCFRAMEWORK}/ios-arm64_x86_64-simulator",
  "OTHER_LDFLAGS" => "$(inherited) -framework PsyBridge",
}.freeze

# --- Sources ---
app_group = main.new_group("App", "App")
provider_group = main.new_group("FileProvider", "FileProvider")
platform_group = main.new_group("Platform", "Platform")
ui_tests_group = main.new_group("PsynguechthyngueUITests", "Tests/PsynguechthyngueUITests")

add_sources(app_group, "App", app)
add_sources(provider_group, "FileProvider", provider)
add_sources(ui_tests_group, "Tests/PsynguechthyngueUITests", ui_tests)
adapter = platform_group.new_file("PsyBridgeAdapter.swift")
[app, provider].each { |t| t.add_file_references([adapter]) }

app_group.new_file("Info.plist")
app_group.new_file("Psynguechthyngue.entitlements")
provider_group.new_file("Info.plist")
provider_group.new_file("PsyFileProvider.entitlements")

# --- Resources ---
app_resources = app_group.children.find { |c| c.display_name == "Resources" } || app_group.new_group("Resources", "Resources")
%w[Assets.xcassets AppIcon.icon PrivacyInfo.xcprivacy Localizable.xcstrings InfoPlist.xcstrings].each do |name|
  ref = app_resources.new_file(name)
  # Icon Composer bundle: without the type Xcode copies it as a plain folder.
  ref.last_known_file_type = "folder.iconcomposer.icon" if name.end_with?(".icon")
  app.resources_build_phase.add_file_reference(ref)
end
legal_group = main.new_group("Legal", "")
%w[LICENSE NOTICE THIRD_PARTY_NOTICES.md].each do |path|
  app.resources_build_phase.add_file_reference(legal_group.new_file(path))
end

provider_resources = provider_group.new_group("Resources", "Resources")
provider.resources_build_phase.add_file_reference(provider_resources.new_file("PrivacyInfo.xcprivacy"))
provider_strings = provider_resources.new_variant_group("Localizable.strings")
%w[en zh-Hans].each { |lang| provider_strings.new_file("#{lang}.lproj/Localizable.strings").name = lang }
provider.resources_build_phase.add_file_reference(provider_strings)
provider.resources_build_phase.add_file_reference(provider_resources.new_file("Decorations.xcassets"))
# Decoration badge icon (UTTypeIconFiles of the exported badge UTI).
provider_decorations = provider_resources.new_group("Decorations", "Decorations")
%w[KeepDownloadedBadge.png KeepDownloadedBadge@2x.png KeepDownloadedBadge@3x.png].each do |name|
  ref = provider_decorations.new_file(name)
  provider.resources_build_phase.add_file_reference(ref)
  app.resources_build_phase.add_file_reference(ref)
end

# --- Linking: PsySync (SwiftPM, local package) + PsyBridge (static gomobile framework) ---
package = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
package.relative_path = "."
project.root_object.package_references << package

[app, provider].each do |target|
  dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dependency.package = package
  dependency.product_name = "PsySync"
  target.package_product_dependencies << dependency
  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = dependency
  target.frameworks_build_phase.files << build_file
  # PsyBridge (static, link only, never embedded): PSYBRIDGE_LINK_SETTINGS.
  target.add_dependency(bootstrap)
end

app.add_dependency(provider)
ui_tests.add_dependency(app)
embed = app.new_copy_files_build_phase("Embed Foundation Extensions")
embed.dst_subfolder_spec = "13"
embed.add_file_reference(provider.product_reference, true).settings = { "ATTRIBUTES" => %w[RemoveHeadersOnCopy] }

# --- Build settings ---
project.build_configurations.each do |c|
  c.base_configuration_reference = base_config
  c.build_settings.merge!(
    "SDKROOT" => "iphoneos",
    "IPHONEOS_DEPLOYMENT_TARGET" => DEPLOYMENT_TARGET,
    "SWIFT_VERSION" => "6.0",
    "SWIFT_STRICT_CONCURRENCY" => "complete",
  )
end

def configure(target, base_config, settings)
  target.build_configurations.each do |c|
    c.base_configuration_reference = base_config
    c.build_settings.merge!(
      {
        "SDKROOT" => "iphoneos",
        "IPHONEOS_DEPLOYMENT_TARGET" => DEPLOYMENT_TARGET,
        "TARGETED_DEVICE_FAMILY" => "1,2",
        "SWIFT_VERSION" => "6.0",
        "SWIFT_STRICT_CONCURRENCY" => "complete",
        "GENERATE_INFOPLIST_FILE" => "NO",
        "CODE_SIGN_STYLE" => "Automatic",
        "CLANG_ENABLE_MODULES" => "YES",
        "ENABLE_PREVIEWS" => "NO",
      }.merge(settings)
    )
  end
end

configure(app, base_config, PSYBRIDGE_LINK_SETTINGS.merge(
  "PRODUCT_BUNDLE_IDENTIFIER" => "$(APP_BUNDLE_IDENTIFIER)",
  "PRODUCT_NAME" => "Psynguechthyngue",
  "INFOPLIST_FILE" => "App/Info.plist",
  "CODE_SIGN_ENTITLEMENTS" => "App/Psynguechthyngue.entitlements",
  "ASSETCATALOG_COMPILER_APPICON_NAME" => "AppIcon",
  "LD_RUNPATH_SEARCH_PATHS" => "$(inherited) @executable_path/Frameworks",
  "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD" => "YES",
  "SWIFT_EMIT_LOC_STRINGS" => "YES",
))

configure(provider, base_config, PSYBRIDGE_LINK_SETTINGS.merge(
  "PRODUCT_BUNDLE_IDENTIFIER" => "$(FILE_PROVIDER_BUNDLE_IDENTIFIER)",
  "PRODUCT_NAME" => "PsyFileProvider",
  "INFOPLIST_FILE" => "FileProvider/Info.plist",
  "CODE_SIGN_ENTITLEMENTS" => "FileProvider/PsyFileProvider.entitlements",
  "APPLICATION_EXTENSION_API_ONLY" => "YES",
  "SKIP_INSTALL" => "YES",
  "LD_RUNPATH_SEARCH_PATHS" => "$(inherited) @executable_path/../../Frameworks",
  # PSY_RESTRICTED_FETCH switches the extension from the "open the App"
  # fallback to PsyBridgeAdapter's restricted fetch (DESIGN §6.4). Set it in
  # PSY_FILE_PROVIDER_CONDITIONS (Config/Base.xcconfig) once WP-C wires it.
  "SWIFT_ACTIVE_COMPILATION_CONDITIONS" => "$(inherited) $(PSY_FILE_PROVIDER_CONDITIONS)",
))
provider.build_configurations.each do |c|
  next unless c.name == "Debug"
  c.build_settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG $(PSY_FILE_PROVIDER_CONDITIONS)"
end

configure(ui_tests, base_config,
  "PRODUCT_BUNDLE_IDENTIFIER" => "$(APP_BUNDLE_IDENTIFIER).UITests",
  "PRODUCT_NAME" => "PsynguechthyngueUITests",
  "GENERATE_INFOPLIST_FILE" => "YES",
  "TEST_TARGET_NAME" => "Psynguechthyngue",
  "SWIFT_STRICT_CONCURRENCY" => "minimal",
)

project.save

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app, true)
scheme.add_build_target(provider, false)
scheme.add_test_target(ui_tests)
scheme.set_launch_target(app)
scheme.save_as(PROJECT_PATH, "Psynguechthyngue", true)

puts "Generated #{PROJECT_PATH}"
