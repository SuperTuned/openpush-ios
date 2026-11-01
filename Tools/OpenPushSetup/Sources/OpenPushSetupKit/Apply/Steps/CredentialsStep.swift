import Foundation

/// `OpenPushAppID` and `OpenPushSDKKey` in the app's Info.plist, and in the
/// service extension's as its last fallback when the App Group is empty.
struct CredentialsStep: ApplyStep {
    static let appIDKey = "OpenPushAppID"
    static let sdkKeyKey = "OpenPushSDKKey"

    /// The values to write: the options, or what the app's Info.plist already
    /// has. Checked before anything is changed.
    static func credentials(_ project: ScannedProject, app: String, options: ApplyOptions) throws -> (String, String) {
        let info = project.target(named: app)?.primary?.infoPlist ?? [:]
        let appID = options.appID ?? info[appIDKey]?.stringValue
        let sdkKey = options.sdkKey ?? info[sdkKeyKey]?.stringValue
        guard let appID, !appID.isEmpty, let sdkKey, !sdkKey.isEmpty else {
            throw SetupError.missingCredentials((appID?.isEmpty ?? true ? ["--app-id"] : [])
                + (sdkKey?.isEmpty ?? true ? ["--sdk-key"] : []))
        }
        return (appID, sdkKey)
    }

    /// A value written as a build-setting reference, such as `$(OPENPUSH_APP_ID)`.
    static func isReference(_ value: String) -> Bool { value.contains("$(") || value.contains("${") }

    /// Values are compared as they build, so `$(VAR)` matching the option is
    /// left as written. Without an option an existing value is always kept, and
    /// the extension copies the app's reference only when it builds to the same
    /// value there; otherwise it gets the app's value written out.
    func apply(_ context: ApplyContext) throws {
        let (appID, sdkKey) = try Self.credentials(context.project, app: context.plan.appTarget, options: context.options)
        let app = context.plan.appTarget
        let appInfo = try context.infoPlistFiles(of: app).first.map { try context.plist($0) }
        let keys = [(Self.appIDKey, context.options.appID, appID, appInfo?.string(Self.appIDKey)),
                    (Self.sdkKeyKey, context.options.sdkKey, sdkKey, appInfo?.string(Self.sdkKeyKey))]
        let targets = [app] + (context.serviceExtensionTarget.map { [$0] } ?? [])
        for target in targets {
            let expand = context.expander(for: target)
            for path in context.infoPlistFiles(of: target) {
                let document = try context.plist(path)
                for (key, option, value, appRaw) in keys {
                    let raw = document.string(key).flatMap { $0.isEmpty ? nil : $0 }
                    if let option {
                        if let raw, expand(raw) == option { continue }
                        document.set(key, option)
                        if let raw, Self.isReference(raw) {
                            context.report.changed("\(path): \(key) replaces the reference \(raw) with the value given")
                        } else {
                            context.report.changed("\(path): \(key)")
                        }
                    } else if raw == nil {
                        let reference = appRaw.flatMap { Self.isReference($0) && expand($0) == value ? $0 : nil }
                        document.set(key, reference ?? value)
                        context.report.changed("\(path): \(key)\(reference.map { " = \($0)" } ?? "")")
                    }
                }
            }
        }
    }
}
