require 'fourflusher'

PLATFORMS = { 'iphonesimulator' => 'iOS',
              'appletvsimulator' => 'tvOS',
              'watchsimulator' => 'watchOS' }

def build_for_iosish_platform(sandbox, build_dir, target, device, simulator, flags, configuration, build_xcframework=false, libraries, derivedDataPath)
  deployment_target = target.platform_deployment_target
  target_label = target.cocoapods_target_label

  Pod::UI.puts "🍎 Building for iphoneos"
  xcodebuild(sandbox, derivedDataPath, target_label, device, deployment_target, flags, configuration)

  Pod::UI.puts "🍏 Building for iphonesimulator"
  xcodebuild(sandbox, derivedDataPath, target_label, simulator, deployment_target, flags, configuration)

  spec_names = target.specs.map { |spec| [spec.root.name, spec.root.module_name] }.uniq
  spec_names.each do |root_name, module_name|
    if libraries.length > 0 and !libraries.include?(module_name)
      Pod::UI.puts "⚠️ Skip building framework for #{module_name}, libraries: #{libraries}"
      next true
    end

    Pod::UI.puts "🏗 Building framework for #{module_name}"
    device_lib = "#{build_dir}/#{configuration}-#{device}/#{root_name}/#{module_name}.framework"
    simulator_lib = "#{build_dir}/#{configuration}-#{simulator}/#{root_name}/#{module_name}.framework"

    if build_xcframework
      build_xcframework([device_lib, simulator_lib], build_dir, module_name)
    else
      executable_path = "#{build_dir}/#{root_name}"
      build_universal_framework(device_lib, simulator_lib, build_dir, executable_path, module_name)
    end

    # FileUtils.rm device_lib if File.file?(device_lib)
    # FileUtils.rm simulator_lib if File.file?(simulator_lib)
  end
end

def build_for_macos_platform(sandbox, build_dir, target, flags, configuration, build_xcframework=false, derivedDataPath)
  target_label = target.cocoapods_target_label
  xcodebuild(sandbox, derivedDataPath, target_label, flags, configuration)

  spec_names = target.specs.map { |spec| [spec.root.name, spec.root.module_name] }.uniq
  spec_names.each do |root_name, module_name|
    if build_xcframework
      framework = "#{build_dir}/#{configuration}/#{root_name}/#{module_name}.framework"
      build_xcframework([framework], build_dir, module_name)
    end
  end
end

def xcodebuild(sandbox, derivedDataPath, target, sdk='macosx', deployment_target=nil, flags=nil, configuration)
  args = %W(-project #{sandbox.project_path.realdirpath} -scheme #{target} -configuration #{configuration} -sdk #{sdk} -derivedDataPath #{derivedDataPath})
  args += flags unless flags.nil?  
  platform = PLATFORMS[sdk]
  args += Fourflusher::SimControl.new.destination(:oldest, platform, deployment_target) unless platform.nil?
  Pod::Executable.execute_command 'xcodebuild', args, true
end

def build_universal_framework(device_lib, simulator_lib, build_dir, destination, module_name)
  device_executable = "#{device_lib}/#{module_name}"
  simulator_executable = "#{simulator_lib}/#{module_name}"

  raise Pod::Informative, 'Framework executables were not found in the expected location.' unless File.file?(device_executable) && File.file?(simulator_executable)

  device_framework_lib = File.dirname(device_executable)
  lipo_log = `lipo -create -output #{destination} #{device_executable} #{simulator_executable}`
  puts lipo_log unless File.exist?(destination) 

  FileUtils.mv destination, device_executable, :force => true
  FileUtils.mv device_framework_lib, build_dir, :force => true
end

def build_xcframework(frameworks, build_dir, module_name)  
  output = "#{build_dir}/#{module_name}.xcframework"
  args = %W(-create-xcframework -allow-internal-distribution -output #{output})

  frameworks.each do |framework|
    unless File.exist?(framework) 
      return
    end
    args += %W(-framework #{framework})
  end

  Pod::Executable.execute_command 'xcodebuild', args, true
end

def enable_debug_information(project_path, configuration)
  project = Xcodeproj::Project.open(project_path)
  project.targets.each do |target|
    config = target.build_configurations.find { |config| config.name.eql? configuration }
    config.build_settings['DEBUG_INFORMATION_FORMAT'] = 'dwarf-with-dsym'
    config.build_settings['ONLY_ACTIVE_ARCH'] = 'NO'
  end
  project.save
end

def copy_dsym_files(dsym_destination, configuration)
  dsym_destination.rmtree if dsym_destination.directory?
  platforms = ['iphoneos', 'iphonesimulator']
  platforms.each do |platform|
    dsym = Pathname.glob("build/#{configuration}-#{platform}/**/*.dSYM")
    dsym.each do |dsym|
      destination = dsym_destination + platform
      FileUtils.mkdir_p destination
      FileUtils.cp_r dsym, destination, :remove_destination => true
    end
  end
end

Pod::HooksManager.register('cocoapods-rome', :post_install) do |installer_context, user_options|
  enable_dsym = user_options.fetch('dsym', true)
  configuration = user_options.fetch('configuration', 'Debug')
  build_xcframework = user_options.fetch('xcframework', false)
  libraries = user_options.fetch('libraries', [])

  flags = [] 
  
  # Setting SKIP_INSTALL=NO to access the built frameworks inside the archive created
  # instead of searching in Xcode’s default derived data folder
  flags << "SKIP_INSTALL=NO" if build_xcframework

  # Use custom flags passed via user options, if any
  flags += user_options["flags"] if user_options["flags"]
  
  if user_options["pre_compile"]
    user_options["pre_compile"].call(installer_context)
  end

  sandbox_root = Pathname(installer_context.sandbox_root)
  sandbox = installer_context.sandbox

  enable_debug_information(sandbox.project_path, configuration) if enable_dsym

  build_dir = sandbox_root.parent + 'build'
  derivedDataPath = sandbox_root.parent + 'derivedData'
  destination = sandbox_root.parent + 'Rome'

  targets = installer_context.umbrella_targets.select { |t| t.specs.any? }
  targets.each do |target|
    case target.platform_name
    when :ios then build_for_iosish_platform(sandbox, build_dir, target, 'iphoneos', 'iphonesimulator', flags, configuration, build_xcframework, libraries, derivedDataPath)
    when :osx then puts "Skipping osx" # build_for_macos_platform(sandbox, build_dir, target, flags, configuration, build_xcframework, derivedDataPath)
    when :tvos then puts "Skipping tvos" # build_for_iosish_platform(sandbox, build_dir, target, 'appletvos', 'appletvsimulator', flags, configuration, build_xcframework)
    when :watchos then puts "Skipping watchos" # build_for_iosish_platform(sandbox, build_dir, target, 'watchos', 'watchsimulator', flags, configuration, build_xcframework)
    else raise "Unknown platform '#{target.platform_name}'" end
  end

  raise Pod::Informative, 'The build directory was not found in the expected location.' unless build_dir.directory?

  # Make sure the device target overwrites anything in the simulator build, otherwise iTunesConnect
  # can get upset about Info.plist containing references to the simulator SDK
  build_type = build_xcframework ? "xcframework" : "framework"
  frameworks = Pathname.glob("build/*/*/*.#{build_type}").reject { |f| f.to_s =~ /Pods[^.]+\.#{build_type}/ }
  frameworks += Pathname.glob("build/*.#{build_type}").reject { |f| f.to_s =~ /Pods[^.]+\.#{build_type}/ }

  resources = []

  framework_label =  build_xcframework ? 'xcframeworks'.pluralize(frameworks.count) : 'frameworks'.pluralize(frameworks.count)
  Pod::UI.puts "Built #{frameworks.count} #{framework_label}"

  destination.rmtree if destination.directory?

  installer_context.umbrella_targets.each do |umbrella|
    umbrella.specs.each do |spec|
      consumer = spec.consumer(umbrella.platform_name)
      file_accessor = Pod::Sandbox::FileAccessor.new(sandbox.pod_dir(spec.root.name), consumer)
      frameworks += file_accessor.vendored_libraries
      frameworks += file_accessor.vendored_frameworks
      resources += file_accessor.resources
    end
  end
  frameworks.uniq!
  resources.uniq!

  Pod::UI.puts "Copying #{frameworks.count} libraries " \
    "to `#{destination.relative_path_from Pathname.pwd}`"

  FileUtils.mkdir_p destination
  (frameworks + resources).each do |file|
    FileUtils.cp_r file, destination, :remove_destination => true
  end

  copy_dsym_files(sandbox_root.parent + 'dSYM', configuration) if enable_dsym

  if user_options["post_compile"]
    user_options["post_compile"].call(installer_context)
  end

  build_dir.rmtree if build_dir.directory?
end
