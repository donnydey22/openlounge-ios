# Standalone native call engine (Donny t4462u): PJSIP + SRTP + jitter buffer + sound device + teardown.
# No React Native / JS dependency. OpenLoungeCalls (CallKit/PushKit) links it; RN only renders UI.
Pod::Spec.new do |s|
  s.name           = 'OpenLoungeCallEngine'
  s.version        = '0.1.0'
  s.summary        = 'Open Lounge PJSIP call engine (pjproject 2.17)'
  s.license        = 'UNLICENSED'
  s.author         = 'Donny Dey'
  s.homepage       = 'https://openlounge.app'
  s.platforms      = { :ios => '16.4' }
  s.swift_version  = '5.9'
  s.source         = { git: '' }
  s.static_framework = true
  s.vendored_frameworks = 'pjproject.xcframework'
  s.libraries = 'c++'
  s.frameworks = 'AVFoundation', 'AudioToolbox', 'VideoToolbox', 'CoreMedia', 'Network'
  s.source_files   = ['*.{h,c,swift}']
  s.public_header_files = 'OLPjsip.h'
  s.preserve_paths = ['pjproject.xcframework', 'pjinclude/**/*']
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'GCC_PREPROCESSOR_DEFINITIONS' => 'PJ_AUTOCONF=1', 'HEADER_SEARCH_PATHS' => '"${PODS_TARGET_SRCROOT}/pjinclude"' }
end
