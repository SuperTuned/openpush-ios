Pod::Spec.new do |s|
  s.name             = 'OpenPushNSE'
  s.version          = '1.2.2'
  s.summary          = 'Notification Service Extension handler for the OpenPush iOS SDK.'

  s.description      = <<-DESC
    The Notification Service Extension side of the SDK: action buttons, media
    attachments, and the background delivery receipt an extension posts before the
    notification is shown.
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

  s.source_files     = 'Sources/OpenPushNSE/**/*.swift'
  s.resource_bundles = { 'OpenPushNSEPrivacy' => ['Sources/OpenPushNSE/Resources/PrivacyInfo.xcprivacy'] }
  s.frameworks       = 'Foundation', 'UserNotifications'

  s.dependency 'OpenPushCore', s.version.to_s
end
