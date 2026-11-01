Pod::Spec.new do |s|
  s.name             = 'OpenPush'
  s.version          = '1.2.2'
  s.summary          = 'Receive-side iOS SDK for OpenPush.ai.'

  s.description      = <<-DESC
    Registers an iOS device with OpenPush.ai, identifies its user, presents in-app
    messages, and posts notification delivery receipts. The SDK is receive-side
    only: it contains no message creation, campaign management, or send API.

    This is the app-target product. Link `OpenPushNSE` in the Notification Service
    Extension and `OpenPushLiveActivities` in the widget extension; this pod uses
    UIKit and is not extension-safe.
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

  s.source_files     = 'Sources/OpenPush/**/*.swift'
  s.resource_bundles = { 'OpenPushPrivacy' => ['Sources/OpenPush/Resources/PrivacyInfo.xcprivacy'] }
  s.frameworks       = 'Foundation', 'UIKit', 'UserNotifications', 'WebKit', 'SafariServices'
  s.weak_frameworks  = 'ActivityKit'

  s.dependency 'OpenPushCore', s.version.to_s
  s.dependency 'OpenPushLiveActivities', s.version.to_s
end
