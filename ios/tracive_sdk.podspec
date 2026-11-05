#
# The iOS half of the report-form hand-off. Everything else in this package is Dart.
#
Pod::Spec.new do |s|
  s.name             = 'tracive_sdk'
  # Not the package version: Flutter installs this pod from the path, and nothing reads it.
  s.version          = '0.0.1'
  s.summary          = 'Hands a report package to the Tracive app.'
  s.description      = <<-DESC
Writes the report package and presents the "Open in" sheet for the Tracive app.
                       DESC
  s.homepage         = 'https://tracive.id'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Tracive' => 'developer@pleistocent.com' }
  s.source           = { :path => '.' }
  # The Swift Package Manager layout, so CocoaPods and SwiftPM build the same file.
  s.source_files     = 'tracive_sdk/Sources/tracive_sdk/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '12.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
