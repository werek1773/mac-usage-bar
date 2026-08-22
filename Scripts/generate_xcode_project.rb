#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "xcodeproj"

repository_root = File.expand_path("..", __dir__)
project_path = File.join(repository_root, "MacUsageBar.xcodeproj")

if File.exist?(project_path)
  warn "#{project_path} already exists; remove it explicitly before regenerating."
  exit 1
end

project = Xcodeproj::Project.new(project_path)
project.root_object.attributes["LastUpgradeCheck"] = "2660"
project.root_object.attributes["ORGANIZATIONNAME"] = "Mac Usage Bar"

app_group = project.main_group.new_group("MacUsageBar", "MacUsageBar")
main_source = app_group.new_file("main.m")
info_plist = app_group.new_file("Info.plist")
entitlements = app_group.new_file("MacUsageBar.entitlements")
app_icon = app_group.new_file("AppIcon.icns")
privacy_manifest = app_group.new_file("PrivacyInfo.xcprivacy")

target = project.new_target(:application, "MacUsageBar", :osx, "13.0")
target.product_name = "Mac Usage Bar"
target.product_reference.path = "Mac Usage Bar.app"
target.source_build_phase.add_file_reference(main_source)
target.resources_build_phase.add_file_reference(app_icon)
target.resources_build_phase.add_file_reference(privacy_manifest)

frameworks_group = project.frameworks_group
# xcodeproj adds a Cocoa reference tied to a specific installed SDK. Replace it
# with SDKROOT references so the project remains portable across Xcode releases.
target.frameworks_build_phase.files.each(&:remove_from_project)
frameworks_group.groups.select { |group| group.name == "OS X" }.each(&:remove_from_project)
%w[Cocoa.framework CoreGraphics.framework IOKit.framework QuartzCore.framework].each do |framework|
  reference = frameworks_group.new_file("System/Library/Frameworks/#{framework}")
  reference.source_tree = "SDKROOT"
  target.frameworks_build_phase.add_file_reference(reference)
end

project.build_configurations.each do |configuration|
  configuration.build_settings.merge!(
    "CLANG_ENABLE_MODULES" => "YES",
    "MACOSX_DEPLOYMENT_TARGET" => "13.0",
    "SDKROOT" => "macosx"
  )
end

target.build_configurations.each do |configuration|
  configuration.build_settings.delete("ASSETCATALOG_COMPILER_APPICON_NAME")
  configuration.build_settings.delete("ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME")
  configuration.build_settings.merge!(
    "APP_STORE_BUILD" => "1",
    "CLANG_ENABLE_OBJC_ARC" => "YES",
    "CODE_SIGN_ENTITLEMENTS" => "MacUsageBar/MacUsageBar.entitlements",
    "CODE_SIGN_STYLE" => "Automatic",
    "CURRENT_PROJECT_VERSION" => "26",
    "DEAD_CODE_STRIPPING" => "YES",
    "DEVELOPMENT_TEAM" => "4H36TJZAJ3",
    "ENABLE_APP_SANDBOX" => "YES",
    "ENABLE_HARDENED_RUNTIME" => "YES",
    "ENABLE_USER_SCRIPT_SANDBOXING" => "YES",
    "EXECUTABLE_NAME" => "MacUsageBar",
    "GENERATE_INFOPLIST_FILE" => "NO",
    "GCC_PREPROCESSOR_DEFINITIONS" => ["$(inherited)", "APP_STORE_BUILD=1"],
    "INFOPLIST_FILE" => "MacUsageBar/Info.plist",
    "LD_RUNPATH_SEARCH_PATHS" => ["$(inherited)", "@executable_path/../Frameworks"],
    "MARKETING_VERSION" => "1.8.4",
    "PRODUCT_BUNDLE_IDENTIFIER" => "pl.marcin.macusagebar.final",
    "PRODUCT_NAME" => "Mac Usage Bar",
    "SUPPORTED_PLATFORMS" => "macosx"
  )

  if configuration.name == "Release"
    configuration.build_settings.merge!(
      "COPY_PHASE_STRIP" => "YES",
      "DEBUG_INFORMATION_FORMAT" => "dwarf-with-dsym",
      "ONLY_ACTIVE_ARCH" => "NO",
      "STRIP_INSTALLED_PRODUCT" => "YES",
      "VALIDATE_PRODUCT" => "YES"
    )
  end
end

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.set_launch_target(target)
scheme.save_as(project_path, "MacUsageBar", true)

project.save
puts project_path
