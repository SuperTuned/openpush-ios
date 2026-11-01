import Foundation

/// Installed SDKs: Swift package references and pins, and CocoaPods from the
/// Podfile and Podfile.lock, with the targets each one is linked into.
///
/// Every dependency is reported as a candidate. `in_extension` and `openpush`
/// in its details are what let the scan keep only the push-relevant ones,
/// alongside any a vendor fingerprint claims.
public struct DependencyDetector: ProjectSignalDetector {
    public init() {}

    public func findings(in project: ScannedProject) -> [SetupFinding] {
        swiftPackages(in: project) + pods(in: project) + frameworks(in: project)
    }

    // MARK: - Vendored frameworks

    /// One finding per framework file linked from the project's own folders,
    /// with every target linking it.
    private func frameworks(in project: ScannedProject) -> [SetupFinding] {
        var order: [String] = []
        var linkers: [String: [ProjectTarget]] = [:]
        for target in project.targets {
            for path in target.linkedFrameworks {
                if linkers[path] == nil { order.append(path) }
                linkers[path, default: []].append(target)
            }
        }
        return order.map { path in
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            let targets = linkers[path] ?? []
            return SetupFinding(kind: .pushSDK, id: name, source: project.pbxprojPath, details: [
                "manager": "framework",
                "path": .string(path),
                "targets": .strings(targets.map(\.name)),
                "in_extension": .bool(targets.contains { Self.isNotificationExtension($0.role) }),
                "openpush": .bool(name.hasPrefix("OpenPush")),
            ])
        }
    }

    // MARK: - Swift packages

    private func swiftPackages(in project: ScannedProject) -> [SetupFinding] {
        let resolved = PackageResolved.locations(for: project).compactMap { url in
            (try? Data(contentsOf: url)).flatMap(PackageResolved.init).map { (url, $0) }
        }
        let pins = resolved.flatMap { url, file in file.pins.map { (url, $0) } }
        var findings: [SetupFinding] = []
        var seen: Set<String> = []
        for package in project.remotePackages {
            let identity = PackageResolved.identity(of: package.url)
            seen.insert(identity)
            let linked = project.targets.flatMap { target in
                target.packageProducts.filter {
                    $0.repositoryURL.map(PackageResolved.normalizedURL) == PackageResolved.normalizedURL(package.url)
                }.map { (target, $0.name) }
            }
            let targets = linked.map(\.0)
            findings.append(SetupFinding(kind: .pushSDK, id: identity, source: project.pbxprojPath, details: [
                "manager": "spm",
                "url": .string(package.url),
                "requirement": .optional(package.requirement),
                "version": .optional(pins.first { $0.1.identity == identity }?.1.version),
                "products": .strings(unique(linked.map(\.1))),
                "targets": .strings(unique(targets.map(\.name))),
                "in_extension": .bool(targets.contains { Self.isNotificationExtension($0.role) }),
                "openpush": .bool(Self.isOpenPush(identity)),
            ]))
        }
        for (url, pin) in pins where !seen.contains(pin.identity) {
            seen.insert(pin.identity)
            findings.append(SetupFinding(kind: .pushSDK, id: pin.identity, source: project.relativePath(url), details: [
                "manager": "spm",
                "url": .string(pin.location),
                "version": .optional(pin.version),
                "targets": .strings([]),
                "in_extension": false,
                "openpush": .bool(Self.isOpenPush(pin.identity)),
            ]))
        }
        return findings
    }

    // MARK: - CocoaPods

    private func pods(in project: ScannedProject) -> [SetupFinding] {
        let podfile = project.read("Podfile").map(Podfile.init)
        let lock = project.read("Podfile.lock").map(PodfileLock.init)
        guard podfile != nil || lock != nil else { return [] }
        var names = podfile?.declarations.map(\.name) ?? []
        for pod in lock?.pods ?? [] where !names.contains(pod.name) && podfile == nil {
            names.append(pod.name)
        }
        return names.map { name in
            let declaration = podfile?.declarations.first { $0.name == name }
            let locked = lock?.pods.first { $0.name == name }
            let targets = declaration?.targets ?? []
            return SetupFinding(kind: .pushSDK, id: name, source: podfile == nil ? "Podfile.lock" : "Podfile",
                                editable: false, details: [
                "manager": "cocoapods",
                "requirement": .optional(declaration?.requirement),
                "version": .optional(locked?.version),
                "subspecs": .strings(locked?.subspecs ?? []),
                "targets": .strings(targets),
                "in_extension": .bool(targets.contains {
                    project.target(named: $0).map { Self.isNotificationExtension($0.role) } ?? false
                }),
                "openpush": .bool(name.hasPrefix("OpenPush")),
            ])
        }
    }

    // MARK: - Helpers

    static func isNotificationExtension(_ role: ProjectTarget.Role) -> Bool {
        role == .serviceExtension || role == .contentExtension
    }

    static func isOpenPush(_ identity: String) -> Bool { identity == "openpush-ios" }

    private func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}
