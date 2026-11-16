# Adds the NotificationService app extension to ios/Runner.xcodeproj.
# Safe to run again: it does nothing when the target exists.
#   tool/add_notification_extension.sh
require 'xcodeproj'

project = Xcodeproj::Project.open(File.expand_path('../ios/Runner.xcodeproj', __dir__))
name = 'NotificationService'
if project.targets.any? { |t| t.name == name }
  puts "#{name} already present"
  exit 0
end

app = project.targets.find { |t| t.name == 'Runner' }
generated = project.files.find { |f| f.path.to_s.end_with?('Generated.xcconfig') }

ext = project.new_target(:app_extension, name, :ios, '15.0', nil, :swift)

# Flutter builds Debug, Release and Profile; give the extension all three.
release = ext.build_configurations.find { |c| c.name == 'Release' }
unless ext.build_configurations.any? { |c| c.name == 'Profile' }
  profile = ext.add_build_configuration('Profile', :release)
  profile.build_settings.merge!(release.build_settings)
end
ext.build_configurations.each do |c|
  c.base_configuration_reference = generated # FLUTTER_BUILD_NAME and NUMBER
  c.build_settings.merge!(
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.richarddraycott.switchboard.NotificationService',
    'PRODUCT_NAME' => '$(TARGET_NAME)',
    'INFOPLIST_FILE' => "#{name}/Info.plist",
    'CODE_SIGN_ENTITLEMENTS' => "#{name}/#{name}.entitlements",
    'CODE_SIGN_STYLE' => 'Automatic',
    'SWIFT_VERSION' => '5.0',
    'IPHONEOS_DEPLOYMENT_TARGET' => '15.0',
    'TARGETED_DEVICE_FAMILY' => '1,2',
    'SKIP_INSTALL' => 'YES',
    'GENERATE_INFOPLIST_FILE' => 'NO',
    'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks'],
  )
end

group = project.main_group.find_subpath(name, true)
group.set_source_tree('<group>')
group.set_path(name)
ext.add_file_references([group.new_reference('NotificationService.swift')])
group.new_reference('Info.plist')
group.new_reference("#{name}.entitlements")

# The session helper is compiled into both targets.
runner_group = project.main_group['Runner']
shared = runner_group.files.find { |f| f.path == 'SharedSession.swift' } || runner_group.new_reference('SharedSession.swift')
app.add_file_references([shared]) unless app.source_build_phase.files_references.include?(shared)
ext.add_file_references([shared])
runner_group.new_reference('Runner.entitlements') unless runner_group.files.any? { |f| f.path == 'Runner.entitlements' }

app.build_configurations.each do |c|
  c.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements'
end

# Embed the extension, before Flutter's "Thin Binary" script to avoid a
# build cycle.
embed = app.new_copy_files_build_phase('Embed Foundation Extensions')
embed.dst_subfolder_spec = '13' # PlugIns
embed.add_file_reference(ext.product_reference).settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
thin = app.build_phases.index { |p| p.respond_to?(:name) && p.name == 'Thin Binary' }
if thin
  app.build_phases.delete(embed)
  app.build_phases.insert(thin, embed)
end
app.add_dependency(ext)

project.save
puts "Added #{name}"
