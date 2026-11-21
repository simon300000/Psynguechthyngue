#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "xcodeproj"

ROOT = File.expand_path("..", __dir__)
PROJECT_PATH = File.expand_path(
  ENV.fetch("PSY_XCODEPROJ_PATH", File.join(ROOT, "Psynguechthyngue.xcodeproj")),
  ROOT
)

abort("#{PROJECT_PATH} already exists; generation intentionally refuses to overwrite it") if File.exist?(PROJECT_PATH)

project = Xcodeproj::Project.new(PROJECT_PATH)
project.instance_variable_set(:@object_version, 56)
project.root_object.compatibility_version = "Xcode 14.0"
project.root_object.development_region = "en"
project.root_object.known_regions = ["en", "zh-Hans", "Base"]

config_group = project.main_group.new_group("Config", "Config")
base_config = config_group.new_file("Base.xcconfig")
config_group.new_file("Local.xcconfig.example")
project.main_group.new_group("Artifacts", "Artifacts")

app_group = project.main_group.new_group("App", "App")
provider_group = project.main_group.new_group("FileProvider", "FileProvider")
tests_group = project.main_group.new_group("Tests", "Tests/PsyCoreTests")
ui_tests_group = project.main_group.new_group("UITests", "Tests/PsynguechthyngueUITests")
platform_group = project.main_group.new_group("Platform", "Platform")

def add_swift_files(group, directory, target)
  Dir.glob(File.join(directory, "**", "*.swift")).sort.each do |path|
    relative = path.delete_prefix("#{directory}/")
    target.add_file_references([group.new_file(relative)])
  end
end

app = project.new_target(:application, "Psynguechthyngue", :ios, "17.0")
provider = project.new_target(:app_extension, "PsyFileProvider", :ios, "17.0")
tests = project.new_target(:unit_test_bundle, "PsynguechthyngueTests", :ios, "17.0")
ui_tests = project.new_target(:ui_test_bundle, "PsynguechthyngueUITests", :ios, "17.0")
bootstrap = project.new_aggregate_target("MobilebridgeBootstrap")
bootstrap_phase = bootstrap.new_shell_script_build_phase("Build current Mobilebridge source")
bootstrap_phase.shell_path = "/bin/bash"
bootstrap_phase.shell_script = <<~'SH'.strip
  if [[ "${CONFIGURATION:-}" == "Debug" ]]; then
      exec /bin/bash "${SRCROOT}/Scripts/bootstrap.sh" --reuse-verified
  fi
  exec /bin/bash "${SRCROOT}/Scripts/bootstrap.sh"
SH
bootstrap_phase.output_paths = [
  "$(SRCROOT)/Artifacts/Mobilebridge.xcframework",
  "$(SRCROOT)/Artifacts/Mobilebridge.xcframework.provenance.json",
]
bootstrap_phase.always_out_of_date = "1"
bootstrap_phase.show_env_vars_in_log = "0"
bootstrap.build_configurations.each do |configuration|
  configuration.build_settings["ENABLE_USER_SCRIPT_SANDBOXING"] = "NO"
end

add_swift_files(app_group, File.join(ROOT, "App"), app)
add_swift_files(provider_group, File.join(ROOT, "FileProvider"), provider)
add_swift_files(tests_group, File.join(ROOT, "Tests/PsyCoreTests"), tests)
add_swift_files(ui_tests_group, File.join(ROOT, "Tests/PsynguechthyngueUITests"), ui_tests)
# Exercise the actual iOS enumerator and item projection in the hosted unit
# target, with injected temporary storage and no Go process or user container.
%w[ProviderSupport.swift ProviderEnumerator.swift].each do |name|
  tests.add_file_references([provider_group.files.find { |file| file.path == name }])
end


platform_core = platform_group.new_file("GoCoreClient.swift")
app.add_file_references([platform_core])
provider.add_file_references([platform_core])

app_info = app_group.new_file("Info.plist")
app_entitlements = app_group.new_file("Psynguechthyngue.entitlements")
provider_info = provider_group.new_file("Info.plist")
provider_entitlements = provider_group.new_file("PsyFileProvider.entitlements")

resources_group = app_group.new_group("Resources", "Resources")
app.resources_build_phase.add_file_reference(resources_group.new_file("Assets.xcassets"))
app.resources_build_phase.add_file_reference(resources_group.new_file("PrivacyInfo.xcprivacy"))
provider_resources_group = provider_group.new_group("Resources", "Resources")
provider.resources_build_phase.add_file_reference(provider_resources_group.new_file("PrivacyInfo.xcprivacy"))
provider_localizable = project.main_group.new_variant_group("Localizable.strings")
provider_localizable.new_file("FileProvider/Resources/en.lproj/Localizable.strings")
provider_localizable.new_file("FileProvider/Resources/zh-Hans.lproj/Localizable.strings")
provider.resources_build_phase.add_file_reference(provider_localizable)
localizable = project.main_group.new_variant_group("Localizable.strings")
localizable.new_file("App/Resources/en.lproj/Localizable.strings")
localizable.new_file("App/Resources/zh-Hans.lproj/Localizable.strings")
app.resources_build_phase.add_file_reference(localizable)
%w[LICENSE NOTICE THIRD_PARTY_NOTICES.md].each do |path|
  app.resources_build_phase.add_file_reference(project.main_group.new_file(path))
end

package_reference = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
package_reference.relative_path = "."
project.root_object.package_references << package_reference

def link_package_product(project, target, package_reference, product_name)
  dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dependency.package = package_reference
  dependency.product_name = product_name
  target.package_product_dependencies << dependency
  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = dependency
  target.frameworks_build_phase.files << build_file
end

[app, provider, tests].each { |target| link_package_product(project, target, package_reference, "PsyCore") }

app.add_dependency(provider)
app.add_dependency(bootstrap)
provider.add_dependency(bootstrap)
tests.add_dependency(app)
ui_tests.add_dependency(app)
embed_extensions = app.new_copy_files_build_phase("Embed App Extensions")
embed_extensions.dst_subfolder_spec = "13"
extension_build_file = embed_extensions.add_file_reference(provider.product_reference, true)
extension_build_file.settings = { "ATTRIBUTES" => ["CodeSignOnCopy", "RemoveHeadersOnCopy"] }

project.build_configurations.each do |configuration|
  configuration.base_configuration_reference = base_config
  configuration.build_settings["SDKROOT"] = "iphoneos"
  configuration.build_settings["IPHONEOS_DEPLOYMENT_TARGET"] = "17.0"
  configuration.build_settings["SWIFT_VERSION"] = "6.0"
  configuration.build_settings["SWIFT_STRICT_CONCURRENCY"] = "complete"
end

def configure_target(target, base_config, settings)
  target.build_configurations.each do |configuration|
    configuration.base_configuration_reference = base_config
    configuration.build_settings.merge!(
      {
        "SDKROOT" => "iphoneos",
        "IPHONEOS_DEPLOYMENT_TARGET" => "17.0",
        "TARGETED_DEVICE_FAMILY" => "1,2",
        "SWIFT_VERSION" => "6.0",
        "SWIFT_STRICT_CONCURRENCY" => "complete",
        "GENERATE_INFOPLIST_FILE" => "NO",
        "CODE_SIGN_STYLE" => "Automatic",
        "CLANG_ENABLE_MODULES" => "YES",
      }.merge(settings)
    )
  end
end

mobilebridge_link_settings = {
  "FRAMEWORK_SEARCH_PATHS[sdk=iphoneos*]" => "$(inherited) $(SRCROOT)/Artifacts/Mobilebridge.xcframework/ios-arm64",
  "FRAMEWORK_SEARCH_PATHS[sdk=iphonesimulator*]" => "$(inherited) $(SRCROOT)/Artifacts/Mobilebridge.xcframework/ios-arm64_x86_64-simulator",
  "OTHER_LDFLAGS" => "$(inherited) -framework Mobilebridge -lresolv",
}

configure_target(
  app,
  base_config,
  mobilebridge_link_settings.merge(
    "PRODUCT_BUNDLE_IDENTIFIER" => "$(APP_BUNDLE_IDENTIFIER)",
    "PRODUCT_NAME" => "Psynguechthyngue",
    "ASSETCATALOG_COMPILER_APPICON_NAME" => "AppIcon",
    "INFOPLIST_FILE" => "App/Info.plist",
    "CODE_SIGN_ENTITLEMENTS" => "App/Psynguechthyngue.entitlements",
    "LD_RUNPATH_SEARCH_PATHS" => "$(inherited) @executable_path/Frameworks",
    "ENABLE_PREVIEWS" => "NO",
    "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD" => "YES",
  )
)

configure_target(
  provider,
  base_config,
  mobilebridge_link_settings.merge(
    "PRODUCT_BUNDLE_IDENTIFIER" => "$(FILE_PROVIDER_BUNDLE_IDENTIFIER)",
    "PRODUCT_NAME" => "PsyFileProvider",
    "INFOPLIST_FILE" => "FileProvider/Info.plist",
    "CODE_SIGN_ENTITLEMENTS" => "FileProvider/PsyFileProvider.entitlements",
    "APPLICATION_EXTENSION_API_ONLY" => "YES",
    "ENABLE_PREVIEWS" => "NO",
    "SKIP_INSTALL" => "YES",
    "LD_RUNPATH_SEARCH_PATHS" => "$(inherited) @executable_path/../../Frameworks",
  )
)

configure_target(
  tests,
  base_config,
  {
    "PRODUCT_BUNDLE_IDENTIFIER" => "$(APP_BUNDLE_IDENTIFIER).Tests",
    "PRODUCT_NAME" => "PsynguechthyngueTests",
    "FRAMEWORK_SEARCH_PATHS[sdk=iphoneos*]" => "$(inherited) $(SRCROOT)/Artifacts/Mobilebridge.xcframework/ios-arm64",
    "FRAMEWORK_SEARCH_PATHS[sdk=iphonesimulator*]" => "$(inherited) $(SRCROOT)/Artifacts/Mobilebridge.xcframework/ios-arm64_x86_64-simulator",
    "GENERATE_INFOPLIST_FILE" => "YES",
    "INFOPLIST_FILE" => "",
    "BUNDLE_LOADER" => "$(TEST_HOST)",
    "TEST_HOST" => "$(BUILT_PRODUCTS_DIR)/Psynguechthyngue.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Psynguechthyngue",
  }
)

configure_target(
  ui_tests,
  base_config,
  {
    "PRODUCT_BUNDLE_IDENTIFIER" => "$(APP_BUNDLE_IDENTIFIER).UITests",
    "PRODUCT_NAME" => "PsynguechthyngueUITests",
    "GENERATE_INFOPLIST_FILE" => "YES",
    "INFOPLIST_FILE" => "",
    "TEST_TARGET_NAME" => "Psynguechthyngue",
  }
)

project.save

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app, true)
scheme.add_build_target(provider, false)
scheme.add_test_target(tests)
scheme.add_test_target(ui_tests)
physical_e2e_test = Xcodeproj::XCScheme::TestAction::TestableReference::Test.new
physical_e2e_test.identifier = "PhysicalFileProviderE2ETests"
scheme.test_action.testables.first.add_skipped_test(physical_e2e_test)
physical_ui_e2e_test = Xcodeproj::XCScheme::TestAction::TestableReference::Test.new
physical_ui_e2e_test.identifier = "PhysicalFilesUIE2ETests"
scheme.test_action.testables.last.add_skipped_test(physical_ui_e2e_test)
scheme.test_action.should_use_launch_scheme_args_env = false
scheme.test_action.environment_variables = Xcodeproj::XCScheme::EnvironmentVariables.new(
  [
    {
      key: "PSY_XCTEST_PERMISSIVE_ENVIRONMENT",
      value: "1",
      enabled: true,
    },
  ]
)
scheme.set_launch_target(app)
scheme.save_as(PROJECT_PATH, "Psynguechthyngue", true)

physical_scheme = Xcodeproj::XCScheme.new
physical_scheme.add_build_target(app, true)
physical_scheme.add_build_target(provider, false)
physical_scheme.add_build_target(ui_tests, false)
physical_scheme.add_test_target(tests)
physical_scheme.add_test_target(ui_tests)
physical_testable = physical_scheme.test_action.testables.first
physical_testable.use_test_selection_whitelist = true
physical_test = Xcodeproj::XCScheme::TestAction::TestableReference::Test.new
physical_test.identifier = "PhysicalFileProviderE2ETests/testReportPhysicalPeerIdentityAndLANAddress"
physical_testable.add_selected_test(physical_test)
physical_ui_testable = physical_scheme.test_action.testables.last
physical_ui_testable.use_test_selection_whitelist = true
physical_scheme.test_action.should_use_launch_scheme_args_env = false
physical_scheme.test_action.environment_variables = Xcodeproj::XCScheme::EnvironmentVariables.new(
  [
    {
      key: "PSY_XCTEST_PERMISSIVE_ENVIRONMENT",
      value: "1",
      enabled: true,
    },
  ]
)
physical_scheme.set_launch_target(app)
physical_scheme.save_as(PROJECT_PATH, "PsynguechthynguePhysicalE2E", true)

puts "Generated #{PROJECT_PATH}"
