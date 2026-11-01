import Foundation

/// The notification service extension, in the chosen mode:
/// - `take_over` rewrites the principal class as OpenPush's handler, keeping
///   the class name the Info.plist names, the bundle id, signing and
///   entitlements, and drops the vendor's own dependency;
/// - `share` inserts OpenPush's lines into the existing class;
/// - `inject` creates `OpenPushNotificationService`;
/// - `off` changes nothing and says what that costs.
struct ServiceExtensionStep: ApplyStep {
    static let minimumDeploymentTarget = "16.0"

    let fingerprints: [any VendorFingerprint]

    func apply(_ context: ApplyContext) throws {
        guard let choice = context.choices.serviceExtension else { return }
        let group = context.choices.appGroup?.value ?? ""
        switch choice.mode {
        case .off:
            context.report.note("No service extension: OpenPush pushes show no images or action buttons, "
                + "and report no delivery receipts.")
        case .inject:
            try ExtensionTargetFactory().create(.init(
                name: choice.target ?? ChoiceResolver.createdExtensionName,
                bundleID: choice.bundleID ?? ChoiceResolver.createdExtensionName,
                extensionPoint: "com.apple.usernotifications.service",
                principalClass: "$(PRODUCT_MODULE_NAME).NotificationService",
                deploymentTarget: Self.minimumDeploymentTarget,
                sources: ["NotificationService.swift": ExtensionTemplates.serviceExtension(
                    className: "NotificationService", appGroup: group, objcName: false)],
                entitlements: true,
                profiles: choice.profile,
                profileFlag: "--nse-profile"), in: context)
        case .takeOver, .share:
            guard let finding = context.findings.first(where: { $0.kind == .serviceExtension && $0.id == choice.target }),
                  let principal = finding.details["principal_class"]?.stringValue,
                  let file = finding.details["principal_class_file"]?.stringValue else {
                throw SetupError.principalClassNotFound(choice.target ?? "the extension")
            }
            let className = ExtensionTargetDetector.className(principal)
            // Both modes write Swift; an Objective-C class is never rewritten.
            if !file.hasSuffix(".swift") {
                if choice.mode == .takeOver { throw SetupError.takeOverNeedsSwift(file: file) }
                try writePatch(SharePatcher(className: className, appGroup: group)
                    .objectiveCInstructions(target: finding.id, file: file,
                                            infoPlist: finding.details["info_plist"]?.stringValue),
                               context: context)
                throw SetupError.objectiveCExtension(file: file, patch: Self.patchPath)
            }
            if choice.mode == .takeOver {
                try takeOver(finding, className: className, objcName: !principal.contains("."), file: file,
                             group: group, context: context)
            } else {
                try share(finding, className: className, file: file, group: group, context: context)
            }
            raiseDeploymentTarget(of: finding.id, context: context)
        }
    }

    // MARK: - Take over

    private func takeOver(_ finding: SetupFinding, className: String, objcName: Bool, file: String,
                          group: String, context: ApplyContext) throws {
        let replacement = ExtensionTemplates.serviceExtension(className: className, appGroup: group, objcName: objcName)
        if context.project.read(file) != replacement {
            context.stageReplacement(file, Data(replacement.utf8))
            context.report.changed("\(file): \(className) is now OpenPush's handler (the original is in the backup)")
        }
        let vendor = fingerprints.first { $0.vendor == finding.vendor }
        guard let vendor else { return }
        for product in context.editor.unlinkProducts(from: finding.id, where: vendor.isExtensionDependency) {
            context.report.changed("\(finding.id): no longer links \(product)")
        }
        let pods = context.project.read("Podfile").map(Podfile.init)?.declarations ?? []
        for pod in pods where pod.targets.contains(finding.id) && vendor.isExtensionDependency(pod.name) {
            context.report.todo("Podfile: remove pod '\(pod.name)' from target '\(finding.id)', then run pod install")
        }
        for source in finding.details["sources"]?.strings ?? [] where source != file {
            let imports = SourceInspector.imports(in: context.project.read(source) ?? "")
            if imports.contains(where: vendor.isExtensionDependency) {
                context.report.todo("\(source) still uses the previous SDK; remove or rewrite it")
            }
        }
    }

    // MARK: - Share

    private func share(_ finding: SetupFinding, className: String, file: String, group: String,
                       context: ApplyContext) throws {
        let patcher = SharePatcher(className: className, appGroup: group)
        switch patcher.patch(context.project.read(file) ?? "") {
        case .alreadyShared:
            return
        case .patched(let text, let inserted):
            context.stageReplacement(file, Data(text.utf8))
            context.report.changed("\(file): OpenPush handles its own pushes first (\(inserted.count) lines added)")
        case .anchorsMissing(let missing):
            try writePatch(patcher.instructions(file: file, missing: missing), context: context)
            throw SetupError.shareAnchorsMissing(file: file, patch: Self.patchPath)
        }
    }

    static let patchPath = SetupAnswerFile.folder + "/share.patch"

    /// The one file a refused share writes: the lines to add by hand.
    private func writePatch(_ text: String, context: ApplyContext) throws {
        let url = context.project.url(for: Self.patchPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    // MARK: - Deployment target

    /// `OpenPushNSE` needs iOS 16. Raised on the extension only; the extension
    /// runs on the app's devices, so this costs the app nothing.
    private func raiseDeploymentTarget(of target: String, context: ApplyContext) {
        guard let scanned = context.project.target(named: target) else { return }
        let below = scanned.configurations.filter {
            LinkingStep.version($0.settings["IPHONEOS_DEPLOYMENT_TARGET"] ?? "0", isBelow: Self.minimumDeploymentTarget)
        }.map(\.name)
        guard !below.isEmpty else { return }
        context.editor.setSetting("IPHONEOS_DEPLOYMENT_TARGET", Self.minimumDeploymentTarget,
                                  target: target, configurations: below)
        context.report.changed("\(target): IPHONEOS_DEPLOYMENT_TARGET = \(Self.minimumDeploymentTarget)")
    }
}
