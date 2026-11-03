Pod::Spec.new do |s|
  s.name           = 'OpenLoungeCalls'
  s.version        = '0.3.1'
  s.summary        = 'Open Lounge native call ringing: PushKit (VoIP push) + CallKit + call audio session'
  s.description    = s.summary
  s.license        = 'UNLICENSED'
  s.author         = 'Donny Dey'
  s.homepage       = 'https://openlounge.app'
  s.platforms      = { :ios => '16.4' }
  s.swift_version  = '5.9'
  s.source         = { git: '' }
  s.static_framework = true
  s.dependency 'ExpoModulesCore'
  s.vendored_frameworks = 'pjproject.xcframework' # pjproject 2.17, built by .github/workflows/ios-xcframework.yml
  s.libraries = 'c++'
  s.frameworks = 'CallKit', 'PushKit', 'AVFoundation', 'AudioToolbox', 'VideoToolbox', 'CoreMedia', 'Network'
  s.source_files   = '**/*.{h,m,swift}'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'SWIFT_COMPILATION_MODE' => 'wholemodule', 'GCC_PREPROCESSOR_DEFINITIONS' => 'PJ_AUTOCONF=1' }
  s.preserve_paths = 'pjproject.xcframework'
end
