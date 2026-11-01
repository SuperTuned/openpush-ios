Pod::Spec.new do |s|
  s.name             = 'OpenPushVoIP'
  s.version          = '1.2.2'
  s.summary          = 'VoIP push registration and delivery for the OpenPush iOS SDK.'

  s.description      = <<-DESC
    Registers for VoIP pushes with PushKit, keeps the VoIP token on the OpenPush
    server against the device's push subscription, and hands each incoming VoIP
    push to the app, which must report it to CallKit. A separate pod so an app
    without calls never links PushKit.
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

  s.source_files     = 'Sources/OpenPushVoIP/**/*.swift'
  s.resource_bundles = { 'OpenPushVoIPPrivacy' => ['Sources/OpenPushVoIP/Resources/PrivacyInfo.xcprivacy'] }
  s.frameworks       = 'Foundation', 'PushKit', 'UIKit'

  s.dependency 'OpenPush', s.version.to_s
  s.dependency 'OpenPushCore', s.version.to_s
end
