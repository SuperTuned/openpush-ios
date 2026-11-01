import Foundation

/// Creates an extension target beside the app: files, settings and signing,
/// embedding. Shared by the created service extension and widget.
struct ExtensionTargetFactory {
    struct Request {
        let name: String
        let bundleID: String
        let extensionPoint: String
        let principalClass: String?
        let deploymentTarget: String
        let sources: [String: String]
        let entitlements: Bool
        let profiles: ProvisioningProfiles?
        /// The option that supplies the profile, named when one is missing.
        let profileFlag: String
    }

    func create(_ request: Request, in context: ApplyContext) throws {
        guard context.project.target(named: request.name) == nil, let app = context.app else { return }
        let signing = try SigningPolicy.settings(copying: app, profiles: request.profiles,
                                                 target: request.name, flag: request.profileFlag)
        let folder = request.name
        let infoPlist = "\(folder)/Info.plist"
        let entitlements = request.entitlements ? "\(folder)/\(request.name).entitlements" : nil

        var settings: [String: [String: String]] = [:]
        for configuration in app.configurations {
            var values: [String: String] = [
                "PRODUCT_BUNDLE_IDENTIFIER": request.bundleID,
                "PRODUCT_NAME": "$(TARGET_NAME)",
                "INFOPLIST_FILE": infoPlist,
                "GENERATE_INFOPLIST_FILE": "YES",
                "INFOPLIST_KEY_CFBundleDisplayName": request.name,
                "IPHONEOS_DEPLOYMENT_TARGET": request.deploymentTarget,
                "SDKROOT": "iphoneos",
                "TARGETED_DEVICE_FAMILY": "1,2",
                "SWIFT_VERSION": "5.0",
                "SKIP_INSTALL": "YES",
                "APPLICATION_EXTENSION_API_ONLY": "YES",
                "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks",
            ]
            // An extension's version must match its app's for App Store upload.
            for key in ["MARKETING_VERSION", "CURRENT_PROJECT_VERSION"] {
                if let value = configuration.settings[key], !value.isEmpty { values[key] = value }
            }
            if let entitlements { values["CODE_SIGN_ENTITLEMENTS"] = entitlements }
            values.merge(signing[configuration.name] ?? [:]) { _, signed in signed }
            settings[configuration.name] = values
        }

        // Written as documents, so later steps add their keys to the same file.
        let info = try context.plist(infoPlist)
        for (key, value) in ExtensionTemplates.extensionInfoPlist(point: request.extensionPoint,
                                                                  principalClass: request.principalClass) {
            info.set(key, value)
        }
        if let entitlements { try context.plist(entitlements).markChanged() }
        for (file, text) in request.sources.sorted(by: { $0.key < $1.key }) {
            context.stage("\(folder)/\(file)", Data(text.utf8))
        }
        context.editor.addExtension(NewExtensionTarget(
            name: request.name, folder: folder, sourceFiles: request.sources.keys.sorted(),
            supportFiles: ["Info.plist"] + (entitlements.map { [($0 as NSString).lastPathComponent] } ?? []),
            settings: settings), embedIn: app.name)
        context.register(request.name, .init(
            infoPlist: infoPlist, entitlements: entitlements,
            settings: settings.mapValues { ResolvedBuildSettings(layers: [$0]) }))
        context.report.changed("Created \(request.name) (\(request.bundleID)), embedded in \(app.name)")
        for (configuration, values) in signing.sorted(by: { $0.key < $1.key }) where !values.isEmpty {
            let line = values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            context.report.note("\(request.name) (\(configuration)) signs with \(line)")
        }
    }
}
