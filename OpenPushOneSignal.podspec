Pod::Spec.new do |s|
  s.name             = 'OpenPushOneSignal'
  s.version          = '1.2.2'
  s.summary          = 'Opt-in compatibility facade for hosts migrating to the OpenPush iOS SDK.'

  s.description      = <<-DESC
    An opt-in facade that keeps the call-site spelling of the push SDK a host is
    migrating away from, so the move is one import line rather than a rewrite. It
    refuses at compile time any call OpenPush does not implement. Do not link it
    and the SDK it replaces into the same target.

    OneSignal is a trademark of OneSignal, Inc. OpenPush is not affiliated with,
    endorsed by, or sponsored by OneSignal, Inc. The OneSignal name appears only
    to describe the optional compatibility layer for apps migrating from the
    OneSignal SDK.
  DESC

  s.homepage         = 'https://github.com/SuperTuned/openpush-ios'
  s.license          = { :type => 'Apache-2.0', :file => 'LICENSE' }
  s.authors          = 'JuneSoftware Inc'
  s.source           = { :git => 'https://github.com/SuperTuned/openpush-ios.git', :tag => s.version.to_s }

  s.ios.deployment_target = '16.0'
  s.swift_versions        = ['6.0']

  # Matches the package: swift-tools-version 6.0 builds in the Swift 6 language
  # mode, where complete concurrency checking is the default.
  s.pod_target_xcconfig = { 'SWIFT_STRICT_CONCURRENCY' => 'complete' }

  s.source_files     = 'Sources/OpenPushOneSignal/**/*.swift'
  s.resource_bundles = { 'OpenPushOneSignalPrivacy' => ['Sources/OpenPushOneSignal/Resources/PrivacyInfo.xcprivacy'] }
  s.frameworks       = 'Foundation', 'CryptoKit', 'UIKit', 'UserNotifications'
  s.weak_frameworks  = 'ActivityKit'

  s.dependency 'OpenPush', s.version.to_s
  s.dependency 'OpenPushLiveActivities', s.version.to_s
end
