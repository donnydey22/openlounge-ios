# Expo module pod for the OL iOS app (Expo prebuild picks it up from
# modules/openlounge-olcall/ via expo-module.config.json).
#
# Vendors:
#   Frameworks/TgVoipWebrtc.xcframework  - Telegram-iOS //submodules/TgVoipWebrtc:TgVoipWebrtc
#       as a static xcframework (ios/OLTgVoipXCFramework, built with the
#       Telegram-iOS Bazel tree at the pin in ci/telegram-ios-versions.pin)
#   audio/core (C11 session policy, unit-tested on Linux) and the OLTgcallsSwift
#       wrapper sources (copied in by ios/install-into-ol-app.sh; single source in this package)
Pod::Spec.new do |s|
  s.name           = 'OpenLoungeOlcall'
  s.version        = '1.0.0'
  s.summary        = 'Open Lounge calls: tgcalls (TgVoipWebrtc) <-> olcall Go/Pion server'
  s.license        = { :type => 'LGPL-3.0 (tgcalls) + OL proprietary glue', :text => 'see docs/LGPL.md' }
  s.author         = 'Open Lounge'
  s.homepage       = 'https://openlounge.app'
  s.platforms      = { :ios => '15.0' }   # = Telegram/BUILD minimum_os_version at the pin
  s.swift_version  = '5.9'
  s.source         = { :path => '.' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'

  # tgcalls-swift/ = ios/OLTgcallsSwift/Sources/OLTgcalls (the thin tgcalls wrapper; single source).
  s.source_files        = 'Sources/**/*.swift', 'tgcalls-swift/*.swift', 'audio/core/*.{h,c}'
  # ol_audio.h reaches Swift through modules/OLAudioCore only (not the pod umbrella), so its types are defined once.
  s.private_header_files = 'audio/core/ol_audio.h'
  s.preserve_paths      = 'modules/**/*', 'Frameworks/**/*'
  s.vendored_frameworks = 'Frameworks/TgVoipWebrtc.xcframework'

  s.frameworks = 'AVFoundation', 'AudioToolbox', 'VideoToolbox', 'CoreMedia', 'CoreVideo',
                 'CoreTelephony', 'GLKit', 'Metal', 'MetalKit', 'Network', 'UIKit', 'CryptoKit'
  s.libraries  = 'z', 'c++', 'bz2', 'iconv'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    # module maps: OLAudioCore (audio/core/ol_audio.h) and TgVoipWebrtc (xcframework headers)
    'SWIFT_INCLUDE_PATHS' => '$(PODS_TARGET_SRCROOT)/modules',
    'OTHER_LDFLAGS' => '$(inherited) -ObjC',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'GCC_C_LANGUAGE_STANDARD' => 'c11',
  }
end
