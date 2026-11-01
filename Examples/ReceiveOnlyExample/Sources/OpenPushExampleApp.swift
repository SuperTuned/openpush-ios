import OpenPush
import SwiftUI
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [
            UIApplication.LaunchOptionsKey: Any
        ]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        ExampleSDKBootstrap.startIfPermitted()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        // No manual App Group write: `initialize(… appGroup:)` makes OpenPush
        // mirror the token, the subscription id, and the configuration itself
        // into the group for the Notification Service Extension to read.
        if OpenPush.isInitialized {
            OpenPush.didRegisterForRemoteNotifications(deviceToken: deviceToken)
        }
    }

    /// A background (`content-available`) push never reaches
    /// `UNUserNotificationCenterDelegate`, so without this forward a silent
    /// delivery would leave no record at all. OpenPush posts the receipt and
    /// never calls the completion handler for you.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        if OpenPush.isInitialized {
            OpenPush.didReceiveRemoteNotification(userInfo: userInfo)
        }
        completionHandler(.noData)
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
        // Lifecycle parsing is local-only and keeps Demo mode functional even
        // while live SDK initialization is waiting behind host consent.
        //
        // Both spellings are wired, because the sample exists to show both. The
        // synchronous one answers iOS immediately and is the default. The
        // asynchronous one holds the answer open so a listener that called
        // preventDefault() can still call display() — the only spelling that can
        // honor it — and iOS is answered from there, or suppressed when nothing
        // calls it within the SDK's window.
        guard ForegroundPresentationChoice.shared.current.displayAfterDelay else {
            completionHandler(OpenPush.Notifications.processForeground(notification))
            return
        }
        // UNUserNotificationCenter hands over a plain closure and the SDK's
        // asynchronous spelling takes a Sendable one. iOS calls this delegate on
        // the main thread and the answer goes back the same way, so the hop is
        // the real guarantee behind this annotation.
        nonisolated(unsafe) let answer = completionHandler
        OpenPush.Notifications.processForeground(notification) { options in
            // The one place that knows how the deferral ended: these are the
            // options iOS is about to be given, whether display() arrived in time
            // or the SDK's window closed and the notification is suppressed.
            ForegroundPresentationChoice.shared.reportOutcome(options)
            DispatchQueue.main.async { answer(options) }
        }
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
struct OpenPushExampleApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = ExampleModel()

    var body: some Scene {
        WindowGroup {
            FeatureLabView()
                .environmentObject(model)
                .tint(OpenPushStyle.signal)
                .preferredColorScheme(model.appearance.colorScheme)
                .task { model.appDidBecomeReady() }
                // A tap on the Live Activity opens the SDK's tracking URL, not
                // the app's own. `trackClickAndReturnOriginal` records the click
                // and hands back the destination that was folded into it — or
                // the URL untouched when it was never an OpenPush one, so an
                // unrelated deep link still routes normally.
                .onOpenURL { url in
                    model.handleWidgetURL(
                        OpenPush.LiveActivities.trackClickAndReturnOriginal(url)
                    )
                }
        }
    }
}

private struct FeatureLabView: View {
    @EnvironmentObject private var model: ExampleModel

    var body: some View {
        TabView {
            NavigationStack { StatusScreen() }
                .tabItem { Label("Status", systemImage: "dot.radiowaves.left.and.right") }

            NavigationStack { UserScreen() }
                .tabItem { Label("User", systemImage: "person.text.rectangle") }

            NavigationStack { EventsScreen() }
                .tabItem { Label("Events", systemImage: "waveform.path.ecg") }

            NavigationStack { ActivityScreen() }
                .tabItem { Label("Activity", systemImage: "livephoto") }

            NavigationStack { InAppScreen() }
                .tabItem { Label("In-app", systemImage: "rectangle.on.rectangle.angled") }
        }
        .background(OpenPushStyle.paper.ignoresSafeArea())
    }
}
