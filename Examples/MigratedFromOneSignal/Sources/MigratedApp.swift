// A receive-only app that used to run on OneSignal v5 and now runs on OpenPush.
//
// The pre-migration version of this sample app is next door, at
// Before/MigratedApp.swift.onesignal, so the migration is a diff anyone can
// reproduce rather than a claim in a README:
//
//     diff -u Before/MigratedApp.swift.onesignal Sources/MigratedApp.swift
//
// See README.md for that diff, annotated.

import OpenPushOneSignal
import SwiftUI
import UIKit
import UserNotifications

@MainActor
final class ExampleModel: ObservableObject {
    @Published var status = "not registered"
    @Published var identity = "anonymous"
    @Published var inApp = "in-app display live"

    func requestPermission() {
        OneSignal.Notifications.requestPermission({ granted in
            Task { @MainActor in
                self.status = granted ? "authorized" : "not authorized"
            }
        }, fallbackToSettings: true)
    }

    /// A real host passes its own user identifier. Identity verification takes an
    /// auth hash computed by your server — never on the device.
    func signIn() {
        OneSignal.login("demo-user")
        OneSignal.User.addTag(key: "example_build", value: "migrated-from-onesignal")
        identity = "identified as demo-user"
        // OneSignal.User.setLanguage("en")  // compile-time refusal: OpenPush sends the device language
    }

    func signOut() {
        OneSignal.logout()
        identity = "anonymous"
    }

    func optOut() {
        OneSignal.User.pushSubscription.optOut()
        refreshSubscription()
    }

    func optIn() {
        OneSignal.User.pushSubscription.optIn()
        refreshSubscription()
    }

    func tagAlias() {
        OneSignal.User.addAlias(label: "example_player_id", id: "p-1042")
    }

    /// Counted once per device however often this runs: the outcome carries an
    /// idempotency key derived from its name and this installation's subscription
    /// id, and the server keeps the first one. Record it after registration —
    /// before there is a subscription id the key falls back to a digest, so an
    /// outcome recorded in that window is a second event.
    func recordUniqueOutcome() {
        OneSignal.Session.addUniqueOutcome("demo")
    }

    /// The counted form: every call is its own event.
    func recordOutcome() {
        OneSignal.Session.addOutcome("demo_repeat")
    }

    /// The number rides along as a `value` property. To see it summed rather
    /// than counted, define a conversion metric over the event with
    /// `tracking = value` and `value_property = "value"`.
    func recordOutcomeWithValue() {
        OneSignal.Session.addOutcomeWithValue("demo_revenue", NSNumber(value: 9.99))
    }

    /// Triggers qualify in-app messages, exactly as they did on v5.
    func addInAppTrigger() {
        OneSignal.InAppMessages.addTrigger("example_screen", withValue: "settings")
        inApp = "trigger example_screen=settings"
    }

    /// `paused` both reads and writes, so a host can suppress display without
    /// unregistering anything.
    func toggleInAppMessages() {
        OneSignal.InAppMessages.paused = !OneSignal.InAppMessages.paused
        inApp = OneSignal.InAppMessages.paused ? "in-app display paused" : "in-app display live"
    }

    func refreshSubscription() {
        let subscription = OneSignal.User.pushSubscription
        status = """
        id: \(subscription.id ?? "—")
        token: \(subscription.token ?? "—")
        opted in: \(subscription.optedIn ? "yes" : "no")
        external id: \(OneSignal.User.externalId ?? "anonymous")
        can ask for permission: \(OneSignal.Notifications.canRequestPermission ? "yes" : "no")
        system permission: \(OneSignal.Notifications.permissionNative)
        """
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// The compat facade takes a closure and hands back a handle, so keep it if
    /// you ever want to remove the listener; v5's protocol object has no
    /// equivalent here.
    private var inAppClickHandle: UUID?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [
            UIApplication.LaunchOptionsKey: Any
        ]? = nil
    ) -> Bool {
        OneSignal.initialize("replace-with-app-id", withLaunchOptions: launchOptions)
        UNUserNotificationCenter.current().delegate = self
        _ = OneSignal.Notifications.addClickListener { event in
            print("example · notification click \(event.messageId ?? "—")")
        }
        inAppClickHandle = OneSignal.InAppMessages.addClickListener { _ in
            print("example · in-app click")
        }
        _ = OneSignal.InAppMessages.addLifecycleListener { event in
            print("example · in-app lifecycle \(event.phase) \(event.messageId)")
        }
        if #available(iOS 16.1, *) {
            // Live Activity push updates with no ActivityAttributes type of your
            // own: the facade registers for the default activity's tokens.
            OneSignal.LiveActivities.setupDefault()
        }
        // OneSignal.Notifications.setBadgeCount(0)  // compile-time refusal: manage the badge with UNUserNotificationCenter
        return true
    }
}

extension AppDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        OneSignal.didRegisterForRemoteNotifications(deviceToken: deviceToken)
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(OneSignal.Notifications.processForeground(notification))
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        OneSignal.Notifications.processClick(response)
        completionHandler()
    }
}

@main
struct MigratedFromOneSignalApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = ExampleModel()

    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 16) {
                Text("Migrated from OneSignal").font(.headline)
                Text(model.status).font(.footnote).monospaced()
                Text(model.identity).font(.footnote)
                Text(model.inApp).font(.footnote)
                Button("Enable notifications") { model.requestPermission() }
                Button("Sign in as demo-user") { model.signIn() }
                Button("Sign out") { model.signOut() }
                Button("Refresh subscription") { model.refreshSubscription() }
                Button("Opt out of push") { model.optOut() }
                Button("Opt back in") { model.optIn() }
                Button("Add player alias") { model.tagAlias() }
                Button("Record unique outcome") { model.recordUniqueOutcome() }
                Button("Record counted outcome") { model.recordOutcome() }
                Button("Record outcome with value") { model.recordOutcomeWithValue() }
                Button("Add in-app trigger") { model.addInAppTrigger() }
                Button("Pause/resume in-app") { model.toggleInAppMessages() }
            }
            .padding()
        }
    }
}
