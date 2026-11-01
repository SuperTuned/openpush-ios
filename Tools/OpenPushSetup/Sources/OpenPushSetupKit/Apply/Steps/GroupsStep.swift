import Foundation

/// The chosen App Group, and the Keychain group when there is one, on the app
/// and the service extension, merged into each entitlements file they sign with.
struct GroupsStep: ApplyStep {
    func apply(_ context: ApplyContext) throws {
        // Only an extension reads the group. With none, a new group would be
        // an entitlement (and, under manual signing, a profile) for nothing.
        if context.serviceExtensionTarget == nil, context.choices.appGroup?.mode == .new {
            context.report.note("No service extension, so no App Group is added.")
            return
        }
        let targets = [context.plan.appTarget] + (context.serviceExtensionTarget.map { [$0] } ?? [])
        for target in targets {
            let expand = context.expander(for: target)
            for path in context.entitlementsFiles(of: target) {
                let document = try context.plist(path)
                if let group = context.choices.appGroup?.value,
                   document.addToArray("com.apple.security.application-groups", group, expand: expand) {
                    context.report.changed("\(path): App Group \(group)")
                }
                if let keychain = context.choices.keychainGroup, keychain.mode != .none, let value = keychain.value,
                   document.addToArray("keychain-access-groups", value, expand: expand) {
                    context.report.changed("\(path): Keychain group \(value)")
                }
            }
        }
        if context.choices.appGroup?.mode == .new {
            context.report.note("New App Group \(context.choices.appGroup?.value ?? ""): automatic signing registers it; "
                + "under manual signing add it to both App IDs and regenerate their profiles before building.")
        }
    }
}
