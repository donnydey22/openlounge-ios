# Call control on the app's own socket (CallSignalClient, openlounge.app/ws) + call disk log. No WebRTC: media is
# the olcall engine (modules/openlounge-olcall, Telegram TgVoipWebrtc). WebRTC.xcframework removed 2026-11-10.
# No React Native / JS dependency. OpenLoungeCalls (CallKit/PushKit) links it; RN only renders UI.
Pod::Spec.new do |s|
  s.name           = 'OpenLoungeCallEngine'
  s.version        = '0.1.0'
  s.summary        = 'Open Lounge call control socket (CallSignalClient) + call disk log'
  s.license        = 'UNLICENSED'
  s.author         = 'Donny Dey'
  s.homepage       = 'https://openlounge.app'
  s.platforms      = { :ios => '16.4' }
  s.swift_version  = '5.9'
  s.source         = { git: '' }
  s.static_framework = true
  s.libraries = 'c++'
  s.frameworks = 'Foundation', 'UIKit', 'Security'
  s.source_files   = ['*.swift']
  s.dependency 'ExpoModulesCore'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
