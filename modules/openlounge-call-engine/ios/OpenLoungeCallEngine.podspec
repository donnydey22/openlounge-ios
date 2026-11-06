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
  # Call audio/PC: WebRTC.xcframework (BSD; NOT RingRTC/AGPL). Interim: stasel/WebRTC M152 (branch-heads/7977,
  # same milestone as Android webrtc-bsd/m152). Eventual: signalapp/webrtc 8037b via
  # /workspace/builds/signal-webrtc/build-signal-webrtc-ios.sh (Mac). Fetch: scripts/ios-fetch-webrtc.sh →
  # ios/WebRTC.xcframework. OLCallAudioEngine + OLRtcCall use `canImport(WebRTC)`; without the framework they
  # report webrtc_not_linked / failed("WebRTC framework not linked") — never silent audio or TURN fallback.
  # pjproject.xcframework remains REQUIRED on this branch: leftover video helpers (ol_sfu_video.c,
  # NativeCallMedia.swift, OLVideoEncoder.swift, PJSIPEngine) still compile/link against it. Call audio +
  # P2P media use WebRTC only (OLCallAudioEngine / OLRtcCall). Do not remove pjproject until video moves
  # onto the PeerConnection. CI: .github/workflows/signal-identical-ios.yml fetches/builds it.
  s.vendored_frameworks = ['pjproject.xcframework'] + (File.exist?(File.join(__dir__, 'WebRTC.xcframework')) ? ['WebRTC.xcframework'] : [])
  s.public_header_files = ['OLPjsip.h', 'ol_sfu.h', 'ol_sfu_video.h', 'ol_p2p.h']
  s.preserve_paths = ['pjproject.xcframework', 'WebRTC.xcframework', 'pjinclude/**/*']
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'GCC_PREPROCESSOR_DEFINITIONS' => 'PJ_AUTOCONF=1', 'HEADER_SEARCH_PATHS' => '"${PODS_TARGET_SRCROOT}/pjinclude"' }
end
