import OpenPush
import SwiftUI
import UIKit
import UserNotifications

/// What a device tester needs from this sample: whether push is allowed, the
/// APNs token, and the OpenPush subscription id once OpenPush has registered.
@MainActor
final class PushState: ObservableObject {
    static let shared = PushState()

    @Published var permission = "not asked"
    @Published var apnsToken: String?
    @Published var subscriptionID: String?

    private var observer: UUID?

    func startObserving() {
        guard observer == nil else { return }
        observer = OpenPush.PushSubscription.addObserver { state in
            Task { @MainActor in PushState.shared.subscriptionID = state.id }
        }
        subscriptionID = OpenPush.User.pushSubscription.id
    }
}

enum SampleConfiguration {
    static let appGroup = infoString("SharedExtensionAppGroup")
    static let appID = infoString("OpenPushAppID")

    /// Placeholder credentials leave OpenPush uninitialized: the app still
    /// registers for push, and the extension still runs its own code.
    static var hasCredentials: Bool {
        guard let appID, !appID.hasPrefix("replace-with-"),
              let key = infoString("OpenPushSDKKey"),
              !key.hasPrefix("replace-with-") else { return false }
        return true
    }

    private static func infoString(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty else { return nil }
        return value
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        if SampleConfiguration.hasCredentials, let appID = SampleConfiguration.appID {
            // `appGroup` is what the extension reads: OpenPush mirrors the app id,
            // server, SDK key, APNs token and subscription id into it.
            OpenPush.initialize(appId: appID, appGroup: SampleConfiguration.appGroup)
            Task { @MainActor in PushState.shared.startObserving() }
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in PushState.shared.apnsToken = hex }
        if OpenPush.isInitialized {
            OpenPush.didRegisterForRemoteNotifications(deviceToken: deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        if OpenPush.isInitialized {
            OpenPush.didFailToRegisterForRemoteNotifications(error: error)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(OpenPush.Notifications.processForeground(notification))
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        OpenPush.Notifications.processClick(response)
        completionHandler()
    }
}

@main
struct SharedExtensionExampleApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = PushState.shared

    var body: some Scene {
        WindowGroup {
            PushStatusView(state: state)
        }
    }
}

private struct PushStatusView: View {
    @ObservedObject var state: PushState

    var body: some View {
        NavigationStack {
            List {
                Section("OpenPush") {
                    LabeledContent("Initialized", value: OpenPush.isInitialized ? "yes" : "no — placeholder credentials")
                    LabeledContent("App Group", value: SampleConfiguration.appGroup ?? "none")
                }
                Section("Push") {
                    LabeledContent("Permission", value: state.permission)
                    Button("Allow notifications", action: requestPermission)
                }
                Section("APNs token") {
                    copyable(state.apnsToken, placeholder: "Not registered yet")
                }
                Section("Subscription id") {
                    copyable(state.subscriptionID, placeholder: "Not registered yet")
                }
            }
            .navigationTitle("Shared extension")
        }
    }

    @ViewBuilder
    private func copyable(_ value: String?, placeholder: String) -> some View {
        if let value {
            Text(value)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
        } else {
            Text(placeholder).foregroundStyle(.secondary)
        }
    }

    private func requestPermission() {
        if OpenPush.isInitialized {
            OpenPush.Notifications.requestPermission { granted in
                Task { @MainActor in state.permission = granted ? "allowed" : "denied" }
            }
            return
        }
        // Without OpenPush the app asks iOS itself, so the token still shows.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            Task { @MainActor in
                state.permission = granted ? "allowed" : "denied"
                if granted { UIApplication.shared.registerForRemoteNotifications() }
            }
        }
    }
}
