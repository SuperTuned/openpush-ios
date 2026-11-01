import Foundation

/// Turns an `.xcodeproj` into the model the detectors read.
public protocol ProjectLoading {
    func load(_ projectURL: URL) throws -> ScannedProject
}

public enum ProjectLocator {
    /// `path` may be the `.xcodeproj` itself or the folder holding exactly one.
    /// CocoaPods' own `Pods.xcodeproj` is never the host's project.
    public static func locate(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if url.pathExtension == "xcodeproj" {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw SetupError.noProject(url.deletingLastPathComponent().path)
            }
            return url
        }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        let projects = entries.filter { $0.hasSuffix(".xcodeproj") && $0 != "Pods.xcodeproj" }.sorted()
        switch projects.count {
        case 0: throw SetupError.noProject(url.path)
        case 1: return url.appendingPathComponent(projects[0])
        default: throw SetupError.ambiguousProject(projects)
        }
    }
}
