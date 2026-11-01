Pod::Spec.new do |s|
  s.name             = 'OpenPushCore'
  s.version          = '1.2.2'
  s.summary          = 'Shared configuration, payload parsing, and credential storage for the OpenPush iOS SDK.'

  s.description      = <<-DESC
    The module every other OpenPush product builds on: the configuration type,
    the notification payload parser, the request transport, and the Keychain
    store that holds an installation's device credential.
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

  s.source_files     = 'Sources/OpenPushCore/**/*.swift'
  s.resource_bundles = { 'OpenPushCorePrivacy' => ['Sources/OpenPushCore/Resources/PrivacyInfo.xcprivacy'] }
  s.frameworks       = 'Foundation', 'Security'
end
