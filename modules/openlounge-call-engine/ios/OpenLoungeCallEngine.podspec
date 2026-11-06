# Native call engine: RingRTC session model (OLX3DH-v1 sealed signaling) over BSD WebRTC M152 — audio + video.
# No React Native / JS dependency. OpenLoungeCalls (CallKit/PushKit) links it; RN only renders UI.
Pod::Spec.new do |s|
  s.name           = 'OpenLoungeCallEngine'
  s.version        = '0.1.0'
  s.summary        = 'Open Lounge call engine (RingRTC session model, WebRTC)'
  s.license        = 'UNLICENSED'
  s.author         = 'Donny Dey'
  s.homepage       = 'https://openlounge.app'
  s.platforms      = { :ios => '16.4' }
  s.swift_version  = '5.9'
  s.source         = { git: '' }
  s.static_framework = true
  s.libraries = 'c++'
  s.frameworks = 'AVFoundation', 'AudioToolbox', 'VideoToolbox', 'CoreMedia', 'Network', 'MetalKit', 'Metal', 'CoreVideo', 'UIKit', 'Security'
  s.source_files   = ['*.swift']
  s.dependency 'ExpoModulesCore'
  # Call audio/PC: WebRTC.xcframework (BSD; NOT RingRTC/AGPL). Interim: stasel/WebRTC M152 (branch-heads/7977,
  # same milestone as Android webrtc-bsd/m152). Eventual: signalapp/webrtc 8037b via
  # /workspace/builds/signal-webrtc/build-signal-webrtc-ios.sh (Mac). Fetch: scripts/ios-fetch-webrtc.sh →
  # ios/WebRTC.xcframework. OLCallAudioEngine + OLRtcCall use `canImport(WebRTC)`; without the framework they
  # report webrtc_not_linked / failed("WebRTC framework not linked") — never silent audio or TURN fallback.
  # PJSIP removed (RingRTC session model hard cut): audio + video both ride the one WebRTC PeerConnection
  # (OLCallAudioEngine / OLRtcCall / OLRtcVideo). No SIP stack, no SFU legs, no VideoToolbox fan-out.
  s.vendored_frameworks = File.exist?(File.join(__dir__, 'WebRTC.xcframework')) ? ['WebRTC.xcframework'] : []
  s.preserve_paths = ['WebRTC.xcframework']
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
