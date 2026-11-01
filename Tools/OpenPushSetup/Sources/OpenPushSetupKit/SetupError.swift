import Foundation

public enum SetupError: Error, CustomStringConvertible, Equatable {
    case noProject(String)
    case ambiguousProject([String])
    case unreadableProject(String, String)
    case invalidAnswerFile(String)
    case unknownTarget(String, [String])
    case ambiguousAppTarget([String])
    case noExistingExtension(String)
    case missingChoices([SetupQuestion])
    case missingCredentials([String])
    case manualSigningNeedsProfile(target: String, configurations: [String], flag: String)
    case shareAnchorsMissing(file: String, patch: String)
    case principalClassNotFound(String)
    case unreadablePlist(String)
    case injectWithExistingExtension([String])
    case takeOverNeedsSwift(file: String)
    case objectiveCExtension(file: String, patch: String)

    public var description: String {
        switch self {
        case .noProject(let folder):
            return "No .xcodeproj in \(folder). Pass --project path/to/App.xcodeproj."
        case .ambiguousProject(let candidates):
            return "More than one project found (\(candidates.joined(separator: ", "))). "
                + "Pass --project to choose one."
        case .unreadableProject(let path, let reason):
            return "Could not read \(path): \(reason)"
        case .invalidAnswerFile(let path):
            return "\(path) is not a JSON object. Fix or remove it, then run again."
        case .unknownTarget(let name, let apps):
            return "No app target named \(name). App targets: \(apps.joined(separator: ", "))."
        case .ambiguousAppTarget(let apps):
            return "More than one app target (\(apps.joined(separator: ", "))). Pass --app-target."
        case .noExistingExtension(let mode):
            return "\(mode) needs one existing notification service extension, and none was found to use."
        case .missingChoices(let questions):
            let lines = questions.map { "  - \($0.text) Pass \($0.flag)." }
            return (["Setup needs an answer it will not guess. Run it in a terminal to be asked, or pass:"] + lines)
                .joined(separator: "\n")
        case .missingCredentials(let flags):
            return "The app's Info.plist has no OpenPush credentials. Pass \(flags.joined(separator: " and "))."
        case .manualSigningNeedsProfile(let target, let configurations, let flag):
            return "\(target) would be created under manual signing with no provisioning profile for "
                + "\(configurations.joined(separator: ", ")). Pass \(flag) \"<profile name>\" "
                + "(or \(flag) \"Debug=<name>,Release=<name>\"). Nothing was changed."
        case .injectWithExistingExtension(let targets):
            return "The project already has a notification service extension (\(targets.joined(separator: ", "))), "
                + "and iOS runs one. Use --nse-mode take_over or --nse-mode share instead of inject."
        case .unreadablePlist(let path):
            return "\(path) exists but is not a property list setup can read. Fix it, then run apply again. Nothing was changed."
        case .principalClassNotFound(let target):
            return "Could not find the source file declaring \(target)'s principal class (NSExtensionPrincipalClass). Nothing was changed."
        case .takeOverNeedsSwift(let file):
            return "\(file) is Objective-C, and take_over only rewrites Swift. Use --nse-mode share "
                + "(it writes the steps to add OpenPush beside your class) or --nse-mode off. Nothing was changed."
        case .objectiveCExtension(let file, let patch):
            return "\(file) is Objective-C, so setup does not edit it. The steps to add OpenPush beside it "
                + "are in \(patch); follow them, then run apply again. Nothing was changed."
        case .shareAnchorsMissing(let file, let patch):
            return "Could not find where to add OpenPush in \(file). The lines to add are in \(patch); "
                + "insert them by hand, then run apply again. Nothing was changed."
        }
    }
}
