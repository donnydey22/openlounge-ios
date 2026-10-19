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
  s.frameworks     = 'CallKit', 'PushKit', 'AVFoundation'
  s.source_files   = '**/*.{h,m,swift}'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'SWIFT_COMPILATION_MODE' => 'wholemodule' }
end
