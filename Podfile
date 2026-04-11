platform :ios, '15.6'

# CDN 源必须放在顶部（CocoaPods 1.8+，不走 git clone，无需 pod repo add）
source 'https://cdn.cocoapods.org/'

target 'Xcup' do
  use_frameworks!

  pod 'GoogleMLKit/PoseDetectionAccurate', '8.0.0'
  pod 'TensorFlowLiteSwift'

  target 'XcupTests' do
    inherit! :search_paths
  end

  target 'XcupUITests' do
  end
end

# ✅ post_install 写在 target 外面，完全移除 GTMSessionFetcher 的资源构建步骤
post_install do |installer|
  # 修复 TensorFlowLiteC-xcframeworks.sh Permission denied 问题
  system("find \"#{installer.sandbox.root}\" -name \"*.sh\" -exec chmod +x {} \\;")

  installer.pods_project.targets.each do |target|
    # 修复 Xcode 14+ User Script Sandboxing 导致 TensorFlowLiteC 脚本失败
    target.build_configurations.each do |config|
      config.build_settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
    end

    if target.name.include?("GTMSessionFetcher")
      puts "📦 Found target: #{target.name}"

      target.resources_build_phase.files.each do |file|
        resource = file.display_name
        puts "🔍 Inspecting resource: #{resource}"
        if resource.include?(".bundle") || resource.include?("GTMSessionFetcher_Core_Privacy")
          puts "🚫 Removing problematic resource: #{resource}"
          target.resources_build_phase.remove_build_file(file)
        end
      end
    end
  end
end
