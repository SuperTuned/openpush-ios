import Foundation

/// `OpenPush` in the app, `OpenPushNSE` in the service extension and
/// `OpenPushLiveActivities` in the widget. Swift packages are added to the
/// project; a CocoaPods project gets the Podfile lines to add instead.
struct LinkingStep: ApplyStep {
    func apply(_ context: ApplyContext) throws {
        var links = [(target: context.plan.appTarget, product: "OpenPush")]
        if let service = context.serviceExtensionTarget { links.append((service, "OpenPushNSE")) }
        if let widget = context.choices.widgetExtension, widget.mode != .off, let name = widget.target {
            links.append((name, "OpenPushLiveActivities"))
        }
        // OpenPush already vendored as frameworks (a Unity export) is kept, never
        // linked a second time as a package or a pod.
        links = links.filter { link in
            guard let (path, linker) = vendored(link.product, for: link.target, in: context.project) else { return true }
            context.report.keep("\(link.target): \(link.product) already comes from \(path)"
                + (linker == link.target ? "" : " (linked to \(linker))"))
            return false
        }
        if let app = context.app, let minimum = app.primary?.settings["IPHONEOS_DEPLOYMENT_TARGET"],
           Self.version(minimum, isBelow: "16.0") {
            context.report.todo("\(app.name) targets iOS \(minimum); OpenPush needs iOS 16.0. Raise its deployment target.")
        }
        if context.usesPods {
            let podfile = context.project.read("Podfile").map(Podfile.init)
            for link in links where !(podfile?.declarations.contains {
                $0.name == link.product && $0.targets.contains(link.target)
            } ?? false) {
                context.report.todo("Podfile: in target '\(link.target)' add pod '\(link.product)', '~> \(SetupToolVersion.sdk)', then run pod install")
            }
            return
        }
        for link in links where context.editor.link(link.product, to: link.target, from: context.options.package) {
            context.report.changed("\(link.target): links \(link.product)")
        }
    }

    /// The framework providing `product` to `target`: linked to the target
    /// itself, or — for the app — to a framework target the app is built with.
    private func vendored(_ product: String, for target: String,
                          in project: ScannedProject) -> (String, String)? {
        guard let scanned = project.target(named: target) else { return nil }
        if let path = scanned.linkedFramework(named: product) { return (path, target) }
        guard scanned.role == .app else { return nil }
        for other in project.targets where other.productType == "com.apple.product-type.framework" {
            if let path = other.linkedFramework(named: product) { return (path, other.name) }
        }
        return nil
    }

    static func version(_ value: String, isBelow minimum: String) -> Bool {
        let lhs = value.split(separator: ".").compactMap { Int($0) }
        let rhs = minimum.split(separator: ".").compactMap { Int($0) }
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0, right = index < rhs.count ? rhs[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}
