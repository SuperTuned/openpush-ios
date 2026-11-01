import Foundation
import UserNotifications
import OpenPushCore

/// Downloads the media a push refers to and turns it into a
/// `UNNotificationAttachment` for a notification service extension.
///
/// The loader is deliberately strict, because it runs inside an extension with a
/// short execution budget and hands a file to the system for rendering:
///
/// - `https` only; a cleartext URL is never fetched.
/// - The type must be on the allowlist, decided by the URL's path extension when
///   it has one and by the response's MIME type otherwise.
/// - A body larger than `Options.maxBytes` is refused, on the declared length
///   first and on the bytes that actually landed second.
/// - The whole fetch is bounded by `Options.timeout`.
///
/// The body is never held in memory. It is streamed straight to disk — a chunked
/// response declares no length, and buffering one would blow the extension's
/// memory ceiling long before `maxBytes` could refuse it — and the file is sized,
/// then moved into place.
///
/// Nothing here throws and nothing traps: every path calls `completion` exactly
/// once, with `nil` when the media cannot be used, so a notification still
/// renders as text. The file stays out of UIKit so it remains extension-safe.
public enum OpenPushAttachmentLoader {
    /// The identifier carried by every attachment this loader produces.
    public static let attachmentIdentifier = "openpush-image"

    /// The media types an attachment may have. Everything else is refused.
    static let defaultAllowedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic",
        "mp4", "m4v", "mov",
        "mp3", "m4a", "wav", "aiff",
    ]

    /// The MIME types that name a file extension when the URL does not.
    static let extensionsByMIMEType: [String: String] = [
        "image/jpeg": "jpg", "image/png": "png", "image/gif": "gif", "image/heic": "heic",
        "video/mp4": "mp4", "video/quicktime": "mov",
        "audio/mpeg": "mp3", "audio/mp4": "m4a",
        "audio/wav": "wav", "audio/x-wav": "wav", "audio/aiff": "aiff",
    ]

    public struct Options: Sendable {
        /// Bound on the whole fetch, request and resource alike.
        public var timeout: TimeInterval = 12
        /// Largest body that may become an attachment.
        public var maxBytes: Int = 20 * 1024 * 1024
        /// The file extensions an attachment may have.
        public var allowedExtensions: Set<String> = OpenPushAttachmentLoader.defaultAllowedExtensions
        public init() {}
    }

    /// The fetch seam. The default performs a real request; tests substitute it.
    ///
    /// It hands over a **file**, not bytes: whoever implements it downloads to disk.
    /// The file is consumed synchronously by the completion, the way
    /// `URLSessionDownloadTask` requires — it deletes its temporary file as soon as
    /// the handler returns.
    public typealias Download = @Sendable (URLRequest, @escaping @Sendable (URL?, URLResponse?, Error?) -> Void) -> Void

    /// The extension the downloaded file should be stored under, or `nil` when
    /// the media is not of an allowed type.
    ///
    /// The URL's own path extension wins when it is allowlisted; otherwise the
    /// response's MIME type is mapped. `load` is stricter still: it refuses a URL
    /// whose path extension is present but not allowlisted without fetching it.
    ///
    /// `allowed` is the caller's own allowlist — a host that narrowed
    /// `Options.allowedExtensions` narrows this too, rather than having the URL
    /// judged against the default set.
    public static func fileExtension(for url: URL, mimeType: String?,
                                     allowed: Set<String> = Options().allowedExtensions) -> String? {
        let pathExtension = url.pathExtension.lowercased()
        if allowed.contains(pathExtension) { return pathExtension }
        guard let mimeType else { return nil }
        let bare = mimeType.split(separator: ";", maxSplits: 1).first.map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        guard let bare else { return nil }
        return extensionsByMIMEType[bare]
    }

    /// Fetches `url` and completes with an attachment, or with `nil` when the
    /// media is unusable for any reason.
    public static func load(_ url: URL, options: Options = Options(),
                            download: Download = urlSessionDownload,
                            completion: @escaping @Sendable (UNNotificationAttachment?) -> Void) {
        guard url.scheme?.lowercased() == "https" else { completion(nil); return }
        let pathExtension = url.pathExtension.lowercased()
        guard pathExtension.isEmpty || options.allowedExtensions.contains(pathExtension) else {
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = options.timeout

        download(request) { downloaded, response, error in
            // Synchronously: `URLSessionDownloadTask` removes its temporary file
            // the moment this handler returns.
            guard let file = stagedFile(for: url, downloadedFile: downloaded,
                                        response: response, error: error,
                                        options: options) else {
                completion(nil)
                return
            }
            guard let attachment = try? UNNotificationAttachment(
                identifier: attachmentIdentifier, url: file, options: nil) else {
                try? FileManager.default.removeItem(at: file)
                completion(nil)
                return
            }
            completion(attachment)
        }
    }

    /// Applies every rule to one downloaded file and, when it passes, moves it to a
    /// uniquely named file in the temporary directory. `nil` means refused, and a
    /// refused download is deleted rather than left in the container.
    ///
    /// The bytes are never loaded: the size comes from the file's own attributes,
    /// which is the only thing that can catch a chunked response that declared no
    /// length at all.
    static func stagedFile(for url: URL, downloadedFile: URL?, response: URLResponse?,
                           error: Error?, options: Options) -> URL? {
        guard let downloadedFile else { return nil }
        func refuse() -> URL? {
            try? FileManager.default.removeItem(at: downloadedFile)
            return nil
        }
        guard error == nil else { return refuse() }
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) { return refuse() }
        // Refuse on the declared length before the file is even looked at.
        if let expected = response?.expectedContentLength, expected > 0,
           expected > Int64(options.maxBytes) { return refuse() }
        // The size resource value, not `attributesOfItem`: that call also returns
        // the file's timestamps, which App Store review counts as a
        // required-reason API, and only the size is needed here.
        let size = (try? downloadedFile.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        guard let size, size > 0, size <= options.maxBytes else { return refuse() }
        guard let ext = fileExtension(for: url, mimeType: response?.mimeType,
                                      allowed: options.allowedExtensions),
              options.allowedExtensions.contains(ext) else { return refuse() }

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("openpush-\(UUID().uuidString).\(ext)")
        do {
            try FileManager.default.moveItem(at: downloadedFile, to: file)
        } catch {
            return refuse()
        }
        return file
    }

    /// The default seam: one ephemeral session bounded by the request's timeout,
    /// downloading to disk. A data task would hold the whole body in memory before
    /// any ceiling could apply, and an extension's is roughly 24 MB.
    public static func urlSessionDownload(
        _ request: URLRequest,
        _ completion: @escaping @Sendable (URL?, URLResponse?, Error?) -> Void) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        configuration.timeoutIntervalForResource = request.timeoutInterval
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        session.downloadTask(with: request) { file, response, error in
            completion(file, response, error)
        }.resume()
        session.finishTasksAndInvalidate()
    }
}
