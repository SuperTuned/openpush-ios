import Foundation
import PathKit
import XcodeProj

/// The `.xcodeproj` being changed. All edits go through here, are idempotent,
/// and are written once at the end of a run, after a backup. Only
/// `project.pbxproj` is ever written.
final class ProjectEditor {
    let projectURL: URL
    private let xcodeproj: XcodeProj
    private(set) var changed = false

    init(projectURL: URL) throws {
        self.projectURL = projectURL
        do {
            xcodeproj = try XcodeProj(path: Path(projectURL.path))
        } catch {
            throw SetupError.unreadableProject(projectURL.path, String(describing: error))
        }
    }

    private var pbxproj: PBXProj { xcodeproj.pbxproj }
    private var project: PBXProject { pbxproj.rootObject! }
    private var folder: URL { projectURL.deletingLastPathComponent() }

    /// In the project's own order, so every edit is made the same way each run.
    private var nativeTargets: [PBXNativeTarget] { project.targets.compactMap { $0 as? PBXNativeTarget } }

    func target(_ name: String) -> PBXNativeTarget? { nativeTargets.first { $0.name == name } }

    func configurationNames(of name: String) -> [String] {
        target(name)?.buildConfigurationList?.buildConfigurations.map(\.name) ?? []
    }

    // MARK: - Build settings

    /// Sets a target-level setting in the named configurations (all when nil).
    /// Callers decide whether a value may be replaced; this only writes.
    func setSetting(_ key: String, _ value: String, target name: String, configurations: [String]? = nil) {
        for configuration in target(name)?.buildConfigurationList?.buildConfigurations ?? []
            where configurations?.contains(configuration.name) ?? true {
            if configuration.buildSettings[key]?.stringValue == value { continue }
            configuration.buildSettings[key] = .string(value)
            changed = true
        }
    }

    // MARK: - Packages

    func hasProduct(_ product: String, target name: String) -> Bool {
        target(name)?.packageProductDependencies?.contains { $0.productName == product } ?? false
    }

    /// Links a package product to a target, adding the package reference the
    /// first time. Returns false when the target already had it.
    @discardableResult
    func link(_ product: String, to name: String, from source: OpenPushPackageSource) -> Bool {
        guard let target = target(name), !hasProduct(product, target: name) else { return false }
        let dependency: XCSwiftPackageProductDependency
        switch source {
        case .remote(let url, let version):
            let reference = project.remotePackages.first {
                $0.repositoryURL.map(PackageResolved.normalizedURL) == PackageResolved.normalizedURL(url)
            }
                ?? add(XCRemoteSwiftPackageReference(repositoryURL: url,
                                                     versionRequirement: .upToNextMajorVersion(version))) {
                    project.remotePackages.append($0)
                }
            dependency = add(XCSwiftPackageProductDependency(productName: product, package: reference))
        case .local(let path):
            let relative = Self.relativePath(from: folder, to: URL(fileURLWithPath: path))
            if !project.localPackages.contains(where: { $0.relativePath == relative }) {
                project.localPackages.append(add(XCLocalSwiftPackageReference(relativePath: relative)))
            }
            dependency = add(XCSwiftPackageProductDependency(productName: product))
        }
        target.packageProductDependencies = (target.packageProductDependencies ?? []) + [dependency]
        frameworksPhase(of: target).files = (frameworksPhase(of: target).files ?? [])
            + [add(PBXBuildFile(product: dependency))]
        changed = true
        return true
    }

    /// Unlinks every product of `name` that `matches` accepts; returns their names.
    func unlinkProducts(from name: String, where matches: (String) -> Bool) -> [String] {
        guard let target = target(name) else { return [] }
        let removed = (target.packageProductDependencies ?? []).filter { matches($0.productName) }
        guard !removed.isEmpty else { return [] }
        target.packageProductDependencies = target.packageProductDependencies?.filter { !removed.contains($0) }
        for phase in target.buildPhases.compactMap({ $0 as? PBXFrameworksBuildPhase }) {
            phase.files = phase.files?.filter { file in !removed.contains { $0 === file.product } }
        }
        changed = true
        return removed.map(\.productName)
    }

    // MARK: - Targets

    /// Creates an app extension target, its group and files, and embeds it in
    /// the app. The files themselves are written by the caller.
    func addExtension(_ spec: NewExtensionTarget, embedIn appName: String) {
        guard target(spec.name) == nil, let app = target(appName) else { return }
        let group = add(PBXGroup(children: [], sourceTree: .group, path: spec.folder))
        project.mainGroup.children.append(group)
        let sources = spec.sourceFiles.map { file in
            add(PBXFileReference(sourceTree: .group, lastKnownFileType: "sourcecode.swift", path: file))
        }
        let support = spec.supportFiles.map { file in
            add(PBXFileReference(sourceTree: .group,
                                 lastKnownFileType: file.hasSuffix(".plist") ? "text.plist.xml" : "text.plist.entitlements",
                                 path: file))
        }
        group.children = sources + support

        let product = add(PBXFileReference(sourceTree: .buildProductsDir, explicitFileType: "wrapper.app-extension",
                                           path: "\(spec.name).appex", includeInIndex: false))
        project.productsGroup?.children.append(product)

        let configurations = spec.settings.keys.sorted().map { name in
            add(XCBuildConfiguration(name: name, buildSettings: (spec.settings[name] ?? [:]).mapValues { .string($0) }))
        }
        let list = add(XCConfigurationList(buildConfigurations: configurations,
                                           defaultConfigurationName: configurations.contains { $0.name == "Release" }
                                               ? "Release" : configurations.first?.name))
        let target = add(PBXNativeTarget(
            name: spec.name, buildConfigurationList: list,
            buildPhases: [
                add(PBXSourcesBuildPhase(files: sources.map { add(PBXBuildFile(file: $0)) })),
                add(PBXFrameworksBuildPhase(files: [])),
                add(PBXResourcesBuildPhase(files: [])),
            ],
            productName: spec.name, product: product, productType: .appExtension))
        target.packageProductDependencies = []
        project.targets.append(target)

        let proxy = add(PBXContainerItemProxy(containerPortal: .project(project), remoteGlobalID: .object(target),
                                              proxyType: .nativeTarget, remoteInfo: spec.name))
        app.dependencies.append(add(PBXTargetDependency(target: target, targetProxy: proxy)))
        embedPhase(of: app).files = (embedPhase(of: app).files ?? [])
            + [add(PBXBuildFile(file: product, settings: ["ATTRIBUTES": .array(["RemoveHeadersOnCopy"])]))]
        changed = true
    }

    // MARK: - Synchronized folders

    /// Keeps a file that sits inside a synchronized folder (Xcode 16+) out of
    /// every target that folder belongs to, the way Xcode does for an
    /// Info.plist: otherwise the target also copies it as a resource, and the
    /// build fails with two commands producing the same Info.plist.
    /// Returns the targets it was excluded from.
    func excludeFromSynchronizedFolders(_ relativePath: String) -> [String] {
        let file = folder.appendingPathComponent(relativePath).standardizedFileURL.path
        var excluded: [String] = []
        for target in nativeTargets {
            for group in target.fileSystemSynchronizedGroups ?? [] {
                guard let root = (try? group.fullPath(sourceRoot: folder.path)).flatMap({ $0 }),
                      file.hasPrefix(URL(fileURLWithPath: root).standardizedFileURL.path + "/") else { continue }
                let member = String(file.dropFirst(URL(fileURLWithPath: root).standardizedFileURL.path.count + 1))
                let sets = (group.exceptions ?? []).compactMap { $0 as? PBXFileSystemSynchronizedBuildFileExceptionSet }
                if let existing = sets.first(where: { $0.target === target }) {
                    if existing.membershipExceptions?.contains(member) == true { continue }
                    existing.membershipExceptions = (existing.membershipExceptions ?? []) + [member]
                } else {
                    let exception = add(PBXFileSystemSynchronizedBuildFileExceptionSet(
                        target: target, membershipExceptions: [member], publicHeaders: nil, privateHeaders: nil,
                        additionalCompilerFlagsByRelativePath: nil, attributesByRelativePath: nil))
                    group.exceptions = (group.exceptions ?? []) + [exception]
                }
                excluded.append(target.name)
                changed = true
            }
        }
        return excluded
    }

    // MARK: - Writing

    func save(backup: BackupStore) throws {
        guard changed else { return }
        try backup.preserve(projectURL.appendingPathComponent("project.pbxproj"))
        // Only the pbxproj: writing the whole XcodeProj would also rewrite the
        // shared schemes, breakpoints and user data, none of which setup edits.
        try xcodeproj.pbxproj.write(path: XcodeProj.pbxprojPath(Path(projectURL.path)), override: true)
        changed = false
    }

    // MARK: - Helpers

    @discardableResult
    private func add<T: PBXObject>(_ object: T, then attach: (T) -> Void = { _ in }) -> T {
        pbxproj.add(object: object)
        attach(object)
        return object
    }

    private func frameworksPhase(of target: PBXNativeTarget) -> PBXFrameworksBuildPhase {
        if let phase = target.buildPhases.compactMap({ $0 as? PBXFrameworksBuildPhase }).first { return phase }
        let phase = add(PBXFrameworksBuildPhase(files: []))
        target.buildPhases.append(phase)
        return phase
    }

    private func embedPhase(of app: PBXNativeTarget) -> PBXCopyFilesBuildPhase {
        if let phase = app.buildPhases.compactMap({ $0 as? PBXCopyFilesBuildPhase })
            .first(where: { $0.dstSubfolderSpec == .plugins || $0.dstSubfolder == .plugins }) { return phase }
        let phase = add(PBXCopyFilesBuildPhase(dstPath: "", dstSubfolderSpec: .plugins,
                                               name: "Embed Foundation Extensions", files: []))
        app.buildPhases.append(phase)
        return phase
    }

    static func relativePath(from base: URL, to target: URL) -> String {
        let from = base.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let to = target.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        var shared = 0
        while shared < min(from.count, to.count), from[shared] == to[shared] { shared += 1 }
        let parts = Array(repeating: "..", count: from.count - shared) + to[shared...]
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }
}

/// A target setup creates: everything it needs except the file contents.
struct NewExtensionTarget {
    let name: String
    /// The group and folder its files live in, relative to the project folder.
    let folder: String
    let sourceFiles: [String]
    let supportFiles: [String]
    /// Build settings per configuration name.
    let settings: [String: [String: String]]
}
