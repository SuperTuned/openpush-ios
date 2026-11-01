import Foundation
import PathKit
import XcodeProj

/// Reads a project with XcodeProj. Only this file and the editors touch
/// XcodeProj's types; everything downstream sees `ScannedProject`.
public struct XcodeProjectLoader: ProjectLoading {
    public init() {}

    public func load(_ projectURL: URL) throws -> ScannedProject {
        let project: XcodeProj
        do {
            project = try XcodeProj(path: Path(projectURL.path))
        } catch {
            throw SetupError.unreadableProject(projectURL.path, String(describing: error))
        }
        let pbxproj = project.pbxproj
        let folder = projectURL.deletingLastPathComponent()
        let root = pbxproj.rootObject
        let projectName = projectURL.deletingPathExtension().lastPathComponent
        let projectConfigurations = root?.buildConfigurationList?.buildConfigurations ?? []
        let placeholder = ScannedProject(projectURL: projectURL, targets: [], remotePackages: [])

        // The project's own list, in its order: `pbxproj.nativeTargets` has none,
        // and a scan must read the same way every time.
        let nativeTargets = (root?.targets ?? []).compactMap { $0 as? PBXNativeTarget }
        let embedding = embeddingMap(nativeTargets)
        let targets = nativeTargets.map { target -> ProjectTarget in
            let configurations = (target.buildConfigurationList?.buildConfigurations ?? []).map { configuration in
                let projectLevel = projectConfigurations.first { $0.name == configuration.name }
                let defaults = [
                    "TARGET_NAME": target.name,
                    "PROJECT_NAME": projectName,
                    "CONFIGURATION": configuration.name,
                    "SRCROOT": folder.path,
                    "PROJECT_DIR": folder.path,
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "PRODUCT_MODULE_NAME": "$(PRODUCT_NAME:c99extidentifier)",
                    "EXECUTABLE_NAME": "$(PRODUCT_NAME)",
                ]
                let settings = ResolvedBuildSettings(layers: [
                    xcconfig(projectLevel?.baseConfiguration, folder: folder),
                    strings(projectLevel?.buildSettings),
                    xcconfig(configuration.baseConfiguration, folder: folder),
                    strings(configuration.buildSettings),
                ], defaults: defaults)
                return makeConfiguration(configuration.name, settings: settings, project: placeholder)
            }
            return ProjectTarget(
                name: target.name,
                productType: target.productType?.rawValue,
                configurations: configurations,
                sources: sources(of: target, project: placeholder),
                embeddedIn: embedding[target.name] ?? [],
                packageProducts: (target.packageProductDependencies ?? []).map {
                    .init(name: $0.productName, repositoryURL: $0.package?.repositoryURL)
                },
                linkedFrameworks: frameworks(of: target, project: placeholder))
        }
        let packages = (root?.remotePackages ?? []).compactMap { package -> ScannedProject.RemotePackage? in
            guard let url = package.repositoryURL else { return nil }
            return .init(url: url, requirement: package.versionRequirement.map(describe))
        }
        return ScannedProject(projectURL: projectURL, targets: targets, remotePackages: packages)
    }

    // MARK: - Settings

    private func strings(_ settings: [String: BuildSetting]?) -> [String: String] {
        (settings ?? [:]).mapValues { $0.description }
    }

    private func xcconfig(_ reference: PBXFileReference?, folder: URL) -> [String: String] {
        guard let reference, let path = try? reference.fullPath(sourceRoot: folder.path) else { return [:] }
        return XCConfigFile.settings(at: URL(fileURLWithPath: path))
    }

    private func makeConfiguration(_ name: String, settings: ResolvedBuildSettings,
                                   project: ScannedProject) -> ProjectTarget.Configuration {
        let infoPath = settings["INFOPLIST_FILE"].flatMap(nonEmpty)
        var info = infoPath.flatMap { PropertyListFile.read(project.url(for: $0), settings: settings) } ?? [:]
        if settings.bool("GENERATE_INFOPLIST_FILE") {
            for key in settings.values.keys where key.hasPrefix("INFOPLIST_KEY_") {
                let plistKey = String(key.dropFirst("INFOPLIST_KEY_".count))
                if info[plistKey] == nil, let value = settings[key] { info[plistKey] = .string(value) }
            }
        }
        let entitlementsPath = settings["CODE_SIGN_ENTITLEMENTS"].flatMap(nonEmpty)
        let entitlements = entitlementsPath.flatMap {
            PropertyListFile.read(project.url(for: $0), settings: settings)
        } ?? [:]
        return .init(name: name, settings: settings,
                     infoPlistPath: infoPath.map { project.relativePath(project.url(for: $0)) },
                     infoPlist: info,
                     entitlementsPath: entitlementsPath.map { project.relativePath(project.url(for: $0)) },
                     entitlements: entitlements)
    }

    private func nonEmpty(_ value: String) -> String? { value.isEmpty ? nil : value }

    // MARK: - Structure

    /// Which app targets copy each extension's product into `PlugIns`.
    private func embeddingMap(_ targets: [PBXNativeTarget]) -> [String: [String]] {
        var map: [String: [String]] = [:]
        for host in targets {
            let phases = host.buildPhases.compactMap { $0 as? PBXCopyFilesBuildPhase }
                .filter { $0.dstSubfolderSpec == .plugins || $0.dstSubfolder == .plugins }
            let embedded = phases.flatMap { $0.files ?? [] }.compactMap { $0.file }
            for target in targets where target !== host {
                if let product = target.product, embedded.contains(where: { $0 === product }) {
                    map[target.name, default: []].append(host.name)
                }
            }
        }
        return map
    }

    private func sources(of target: PBXNativeTarget, project: ScannedProject) -> [String] {
        let folder = project.folder.path
        var paths = target.buildPhases.compactMap { $0 as? PBXSourcesBuildPhase }
            .flatMap { $0.files ?? [] }
            .compactMap { try? $0.file?.fullPath(sourceRoot: folder) }
        // A synchronized folder (Xcode 16) lists no files: everything inside it
        // that compiles belongs to the target.
        for group in target.fileSystemSynchronizedGroups ?? [] {
            guard let root = try? group.fullPath(sourceRoot: folder) else { continue }
            let enumerator = FileManager.default.enumerator(atPath: root)
            while let entry = enumerator?.nextObject() as? String {
                if ["swift", "m", "mm"].contains((entry as NSString).pathExtension) {
                    paths.append((root as NSString).appendingPathComponent(entry))
                }
            }
        }
        return paths.map { project.relativePath(URL(fileURLWithPath: $0)) }.sorted()
    }

    private func frameworks(of target: PBXNativeTarget, project: ScannedProject) -> [String] {
        target.buildPhases.compactMap { $0 as? PBXFrameworksBuildPhase }
            .flatMap { $0.files ?? [] }
            .compactMap { $0.file }
            .filter { file in
                guard let path = file.path, path.hasSuffix(".xcframework") || path.hasSuffix(".framework") else { return false }
                return file.sourceTree != .sdkRoot && file.sourceTree != .developerDir
            }
            .compactMap { try? $0.fullPath(sourceRoot: project.folder.path) }
            .map { project.relativePath(URL(fileURLWithPath: $0)) }
    }

    private func describe(_ requirement: XCRemoteSwiftPackageReference.VersionRequirement) -> String {
        switch requirement {
        case .upToNextMajorVersion(let version): return "from \(version)"
        case .upToNextMinorVersion(let version): return "up to next minor from \(version)"
        case .range(let from, let to): return "\(from)..<\(to)"
        case .exact(let version): return "exactly \(version)"
        case .branch(let branch): return "branch \(branch)"
        case .revision(let revision): return "revision \(revision)"
        }
    }
}
