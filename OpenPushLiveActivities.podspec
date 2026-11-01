Pod::Spec.new do |s|
  s.name             = 'OpenPushLiveActivities'
  s.version          = '1.2.2'
  s.summary          = 'Extension-safe Live Activity attributes and widget-URL helpers for the OpenPush iOS SDK.'

  s.description      = <<-DESC
    The Live Activity attributes, content state, and widget-URL helpers, kept in
    their own module so that both the app and a widget extension can link them.
    ActivityKit arrived in iOS 16.1 and the deployment floor is iOS 16.0, so it is
    linked weakly.
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

  s.source_files     = 'Sources/OpenPushLiveActivities/**/*.swift'
  s.resource_bundles = { 'OpenPushLiveActivitiesPrivacy' => ['Sources/OpenPushLiveActivities/Resources/PrivacyInfo.xcprivacy'] }
  s.frameworks       = 'Foundation', 'SwiftUI', 'WidgetKit'
  s.weak_frameworks  = 'ActivityKit'
end
