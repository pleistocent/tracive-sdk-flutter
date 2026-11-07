require 'yaml'
load File.join(File.dirname(__FILE__), 'tracive_core.rb')

pod_dir = File.dirname(__FILE__)
version = YAML.load_file(File.join(pod_dir, '..', 'pubspec.yaml'))['version']
TraciveCore.install(pod_dir: pod_dir, version: version)

Pod::Spec.new do |s|
  s.name             = 'tracive_sdk_extended'
  s.version          = version
  s.summary          = 'Tracive report form, status screen and native core for Flutter.'
  s.description      = <<-DESC
Lets a user report a scammer from inside a partner app, on Tracive's native form or the partner's
own Flutter UI, and check that report's status.
                       DESC
  s.homepage         = 'https://tracive.id'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Tracive' => 'developer@pleistocent.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'tracive_sdk_extended/Sources/tracive_sdk_extended/**/*.swift'
  s.resource_bundles = {
    'TraciveSDKExtended' => ['tracive_sdk_extended/Resources/Privacy/PrivacyInfo.xcprivacy'],
    'TraciveSDKExtendedUI' => ['tracive_sdk_extended/Resources/Strings/*.lproj'],
  }
  s.vendored_frameworks = "Frameworks/#{TraciveCore::NAME}"
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'
  s.swift_version = '5.9'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
end
