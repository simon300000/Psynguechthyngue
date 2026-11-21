#!/usr/bin/env ruby
# frozen_string_literal: true
# DEV/TEST ONLY: generates Tools/FilesHarness/PsyFilesHarness.xcodeproj (git-ignored)
# with the harness app (Tools/FilesHarness + App/Files) and the real File
# Provider extension (FileProvider/**), both linking SwiftPM product PsySync.
require "fileutils"
require "xcodeproj"

HERE = __dir__
ROOT = File.expand_path("../..", HERE)
PATH = File.join(HERE, "PsyFilesHarness.xcodeproj")
FileUtils.rm_rf(PATH)
project = Xcodeproj::Project.new(PATH)

app = project.new_target(:application, "PsyFilesHarness", :ios, "17.0")
ext = project.new_target(:app_extension, "PsyFileProvider", :ios, "17.0")

def add_dir(project, target, dir, group_name, exclude: nil)
  group = project.main_group.new_group(group_name, dir, :absolute)
  Dir.glob(File.join(dir, "**", "*.swift")).sort.each do |path|
    next if exclude && path.include?(exclude)
    target.add_file_references([group.new_reference(path, :absolute)])
  end
  group
end

add_dir(project, app, HERE, "Harness", exclude: "/UITests/")
ui = project.new_target(:ui_test_bundle, "FilesUITests", :ios, "17.0")
add_dir(project, ui, File.join(HERE, "UITests"), "UITests")
ui.add_dependency(app)
add_dir(project, app, File.join(ROOT, "App/Files"), "AppFiles")
fp = add_dir(project, ext, File.join(ROOT, "FileProvider"), "FileProvider")
%w[en zh-Hans].each do |lang|
  ref = fp.new_reference(File.join(ROOT, "FileProvider/Resources/#{lang}.lproj/Localizable.strings"), :absolute)
  ext.resources_build_phase.add_file_reference(ref)
end

pkg = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
pkg.relative_path = "../.."
project.root_object.package_references << pkg
[app, ext].each do |t|
  dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dep.package = pkg
  dep.product_name = "PsySync"
  t.package_product_dependencies << dep
  bf = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  bf.product_ref = dep
  t.frameworks_build_phase.files << bf
end

app.add_dependency(ext)
embed = app.new_copy_files_build_phase("Embed App Extensions")
embed.dst_subfolder_spec = "13"
embed.add_file_reference(ext.product_reference, true).settings = { "ATTRIBUTES" => ["CodeSignOnCopy", "RemoveHeadersOnCopy"] }

common = {
  "IPHONEOS_DEPLOYMENT_TARGET" => "17.0", "TARGETED_DEVICE_FAMILY" => "1,2", "SWIFT_VERSION" => "6.0",
  "SWIFT_STRICT_CONCURRENCY" => "complete", "GENERATE_INFOPLIST_FILE" => "NO",
  "CODE_SIGN_STYLE" => "Manual", "CODE_SIGN_IDENTITY" => "-", "DEVELOPMENT_TEAM" => "",
  "APP_GROUP_IDENTIFIER" => "group.com.example.PsyFilesHarness", "ENABLE_USER_SCRIPT_SANDBOXING" => "NO",
}
app.build_configurations.each do |c|
  c.build_settings.merge!(common).merge!(
    "PRODUCT_BUNDLE_IDENTIFIER" => "com.example.PsyFilesHarness", "PRODUCT_NAME" => "PsyFilesHarness",
    "INFOPLIST_FILE" => File.join(HERE, "Info.plist"), "CODE_SIGN_ENTITLEMENTS" => File.join(HERE, "Harness.entitlements"),
    "LD_RUNPATH_SEARCH_PATHS" => "$(inherited) @executable_path/Frameworks")
end
ext.build_configurations.each do |c|
  c.build_settings.merge!(common).merge!(
    "PRODUCT_BUNDLE_IDENTIFIER" => "com.example.PsyFilesHarness.FileProvider", "PRODUCT_NAME" => "PsyFileProvider",
    "INFOPLIST_FILE" => File.join(ROOT, "FileProvider/Info.plist"),
    "CODE_SIGN_ENTITLEMENTS" => File.join(HERE, "Harness.entitlements"),
    "APPLICATION_EXTENSION_API_ONLY" => "YES", "SKIP_INSTALL" => "YES",
    "LD_RUNPATH_SEARCH_PATHS" => "$(inherited) @executable_path/../../Frameworks")
end
ui.build_configurations.each do |c|
  c.build_settings.merge!(common).merge!(
    "PRODUCT_BUNDLE_IDENTIFIER" => "com.example.PsyFilesHarness.UITests", "PRODUCT_NAME" => "FilesUITests",
    "GENERATE_INFOPLIST_FILE" => "YES", "TEST_TARGET_NAME" => "PsyFilesHarness", "SWIFT_STRICT_CONCURRENCY" => "minimal",
    "CODE_SIGN_ENTITLEMENTS" => "")
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app, true)
scheme.add_build_target(ext, false)
scheme.add_test_target(ui)
scheme.set_launch_target(app)
scheme.save_as(PATH, "PsyFilesHarness", true)
puts "Generated #{PATH}"
