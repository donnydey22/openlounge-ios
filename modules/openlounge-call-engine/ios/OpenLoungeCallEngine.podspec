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
  s.libraries = 'c++'
  s.frameworks = 'AVFoundation', 'AudioToolbox', 'VideoToolbox', 'CoreMedia', 'Network', 'MetalKit', 'Metal', 'CoreVideo', 'UIKit', 'Security'
  s.source_files   = ['*.{h,c,swift}']
  s.dependency 'ExpoModulesCore'
  # Call audio: WebRTC.xcframework built from signalapp/webrtc ref 8037b (BSD; NOT RingRTC/AGPL), vendored at
  # ios/WebRTC.xcframework by scripts/ios-fetch-webrtc.sh on a Mac. OLCallAudioEngine compiles against it via
  # `canImport(WebRTC)`; without it the engine reports `failed("WebRTC framework not linked")` (no silent audio).
  s.vendored_frameworks = ['pjproject.xcframework'] + (File.exist?(File.join(__dir__, 'WebRTC.xcframework')) ? ['WebRTC.xcframework'] : [])
  s.public_header_files = ['OLPjsip.h', 'ol_sfu.h', 'ol_sfu_video.h', 'ol_p2p.h']
  s.preserve_paths = ['pjproject.xcframework', 'pjinclude/**/*']
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'GCC_PREPROCESSOR_DEFINITIONS' => 'PJ_AUTOCONF=1', 'HEADER_SEARCH_PATHS' => '"${PODS_TARGET_SRCROOT}/pjinclude"' }
end
