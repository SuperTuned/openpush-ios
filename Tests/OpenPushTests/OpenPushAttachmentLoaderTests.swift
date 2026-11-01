import XCTest
import UserNotifications
@testable import OpenPushNSE

final class OpenPushAttachmentLoaderTests: XCTestCase {
    /// A 1x1 PNG. Real bytes, so the host's attachment validation has something
    /// it can accept; the loader itself never inspects the contents.
    private let png = Data(base64Encoded: """
        iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==
        """)!

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        private var results: [UNNotificationAttachment?] = []
        func record(_ request: URLRequest) { lock.withLock { requests.append(request) } }
        func downloads() -> Int { lock.withLock { requests.count } }
        func request() -> URLRequest? { lock.withLock { requests.last } }
        func finish(_ attachment: UNNotificationAttachment?) { lock.withLock { results.append(attachment) } }
        func completions() -> Int { lock.withLock { results.count } }
        func attachment() -> UNNotificationAttachment? { lock.withLock { results.last ?? nil } }
    }

    /// A body on disk, the way a real download arrives. Every fake hands over a
    /// file: the seam never carries bytes, so neither the loader nor its tests can
    /// quietly hold a response in memory.
    private func staged(_ data: Data) -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("openpush-test-\(UUID().uuidString)")
        try? data.write(to: file)
        return file
    }

    private func download(_ recorder: Recorder, data: Data?, mime: String?,
                          length: Int? = nil,
                          error: Error? = nil) -> OpenPushAttachmentLoader.Download {
        let file = data.map { staged($0) }
        return { request, completion in
            recorder.record(request)
            guard error == nil else { completion(nil, nil, error); return }
            let response = URLResponse(url: request.url!, mimeType: mime,
                                       expectedContentLength: length ?? (data?.count ?? 0),
                                       textEncodingName: nil)
            completion(file, response, nil)
        }
    }

    private func load(_ string: String, recorder: Recorder,
                      download: OpenPushAttachmentLoader.Download,
                      options: OpenPushAttachmentLoader.Options = .init()) {
        OpenPushAttachmentLoader.load(URL(string: string)!, options: options,
                                      download: download,
                                      completion: { recorder.finish($0) })
    }

    // MARK: - Transport policy

    func testHttpOnly() {
        let recorder = Recorder()
        load("http://cdn.example.com/a.png", recorder: recorder,
             download: download(recorder, data: png, mime: "image/png"))

        XCTAssertEqual(recorder.downloads(), 0, "a cleartext URL must never be fetched")
        XCTAssertEqual(recorder.completions(), 1)
        XCTAssertNil(recorder.attachment())
    }

    func testTheRequestCarriesTheConfiguredTimeout() {
        let recorder = Recorder()
        var options = OpenPushAttachmentLoader.Options()
        options.timeout = 3
        load("https://cdn.example.com/a.png", recorder: recorder,
             download: download(recorder, data: png, mime: "image/png"), options: options)

        XCTAssertEqual(recorder.request()?.timeoutInterval, 3)
        XCTAssertEqual(OpenPushAttachmentLoader.Options().timeout, 12)
    }

    // MARK: - Type policy

    func testUnknownTypeIsRefused() {
        let recorder = Recorder()
        load("https://cdn.example.com/payload.exe", recorder: recorder,
             download: download(recorder, data: png, mime: "image/png"))

        XCTAssertEqual(recorder.downloads(), 0, "a disallowed path extension must not be fetched")
        XCTAssertEqual(recorder.completions(), 1)
        XCTAssertNil(recorder.attachment())
    }

    func testAnUnknownMimeTypeWithoutAPathExtensionIsRefused() {
        let recorder = Recorder()
        load("https://cdn.example.com/media", recorder: recorder,
             download: download(recorder, data: png, mime: "application/octet-stream"))

        XCTAssertEqual(recorder.downloads(), 1)
        XCTAssertEqual(recorder.completions(), 1)
        XCTAssertNil(recorder.attachment())
    }

    func testFileExtensionPrefersTheAllowlistedPathExtension() {
        XCTAssertEqual(OpenPushAttachmentLoader.fileExtension(
            for: URL(string: "https://cdn.example.com/a.JPG")!, mimeType: "image/png"), "jpg")
        XCTAssertEqual(OpenPushAttachmentLoader.fileExtension(
            for: URL(string: "https://cdn.example.com/a.heic")!, mimeType: nil), "heic")
        XCTAssertNil(OpenPushAttachmentLoader.fileExtension(
            for: URL(string: "https://cdn.example.com/a.heic")!, mimeType: nil,
            allowed: ["png"]),
            "a host that narrowed the allowlist narrows the path-extension check too")
    }

    func testFileExtensionMapsEveryAllowedMimeType() {
        let url = URL(string: "https://cdn.example.com/media")!
        let expected = ["image/jpeg": "jpg", "image/png": "png", "image/gif": "gif",
                        "image/heic": "heic", "video/mp4": "mp4", "video/quicktime": "mov",
                        "audio/mpeg": "mp3", "audio/mp4": "m4a", "audio/wav": "wav",
                        "audio/x-wav": "wav", "audio/aiff": "aiff"]
        for (mime, ext) in expected {
            XCTAssertEqual(OpenPushAttachmentLoader.fileExtension(for: url, mimeType: mime), ext, mime)
        }
        XCTAssertEqual(OpenPushAttachmentLoader.fileExtension(
            for: url, mimeType: "image/png; charset=binary"), "png")
        XCTAssertNil(OpenPushAttachmentLoader.fileExtension(for: url, mimeType: "text/html"))
        XCTAssertNil(OpenPushAttachmentLoader.fileExtension(for: url, mimeType: nil))
        XCTAssertNil(OpenPushAttachmentLoader.fileExtension(
            for: URL(string: "https://cdn.example.com/a.exe")!, mimeType: "text/html"))
    }

    // MARK: - Size policy

    func testOversizedContentLengthIsRefusedBeforeReading() {
        let recorder = Recorder()
        // The body is a valid, tiny PNG: only the declared length is oversized,
        // so a nil result proves the header decided it before the bytes did.
        load("https://cdn.example.com/a.png", recorder: recorder,
             download: download(recorder, data: png, mime: "image/png", length: 21 * 1024 * 1024))

        XCTAssertEqual(recorder.completions(), 1)
        XCTAssertNil(recorder.attachment())
        XCTAssertNil(OpenPushAttachmentLoader.stagedFile(
            for: URL(string: "https://cdn.example.com/a.png")!, downloadedFile: staged(png),
            response: URLResponse(url: URL(string: "https://cdn.example.com/a.png")!,
                                  mimeType: "image/png",
                                  expectedContentLength: 21 * 1024 * 1024,
                                  textEncodingName: nil),
            error: nil, options: .init()))
    }

    func testAnUnknownContentLengthIsNotTreatedAsOversized() {
        let recorder = Recorder()
        load("https://cdn.example.com/a.png", recorder: recorder,
             download: download(recorder, data: png, mime: "image/png", length: -1))

        XCTAssertEqual(recorder.completions(), 1)
        XCTAssertNotNil(recorder.attachment())
    }

    func testOversizedBodyIsRefusedEvenWhenTheHeaderLies() {
        let recorder = Recorder()
        var options = OpenPushAttachmentLoader.Options()
        options.maxBytes = 16
        load("https://cdn.example.com/a.png", recorder: recorder,
             download: download(recorder, data: png, mime: "image/png", length: 8), options: options)

        XCTAssertEqual(recorder.completions(), 1)
        XCTAssertNil(recorder.attachment())
    }

    /// The ceiling has to hold against a body that only exists on disk: a chunked
    /// response declares nothing, and the loader must never have read it into
    /// memory to find out how big it was.
    func testAResponseLargerThanMaxBytesOnDiskIsRefused() throws {
        let recorder = Recorder()
        var options = OpenPushAttachmentLoader.Options()
        options.maxBytes = 1024

        let oversized = FileManager.default.temporaryDirectory
            .appendingPathComponent("openpush-test-\(UUID().uuidString).png")
        try Data(repeating: 0x7f, count: 4096).write(to: oversized)
        defer { try? FileManager.default.removeItem(at: oversized) }

        let chunked: OpenPushAttachmentLoader.Download = { request, completion in
            recorder.record(request)
            // `expectedContentLength` is -1 for a chunked response, so only the
            // file on disk can answer the size question.
            let response = URLResponse(url: request.url!, mimeType: "image/png",
                                       expectedContentLength: -1, textEncodingName: nil)
            completion(oversized, response, nil)
        }
        load("https://cdn.example.com/a.png", recorder: recorder, download: chunked,
             options: options)

        XCTAssertEqual(recorder.completions(), 1)
        XCTAssertNil(recorder.attachment())
        XCTAssertFalse(FileManager.default.fileExists(atPath: oversized.path),
                       "a refused download leaves nothing behind in the container")
    }

    // MARK: - Success

    func testASmallPngBecomesAnAttachment() throws {
        let recorder = Recorder()
        load("https://cdn.example.com/a.png", recorder: recorder,
             download: download(recorder, data: png, mime: "image/png"))

        XCTAssertEqual(recorder.completions(), 1)
        let attachment = try XCTUnwrap(recorder.attachment())
        XCTAssertEqual(attachment.identifier, "openpush-image")
        XCTAssertEqual(attachment.url.pathExtension, "png")
    }

    func testMimeTypeWinsWhenThePathHasNoExtension() {
        let recorder = Recorder()
        load("https://cdn.example.com/media/42", recorder: recorder,
             download: download(recorder, data: png, mime: "image/jpeg"))

        XCTAssertEqual(recorder.completions(), 1)
        XCTAssertEqual(recorder.attachment()?.url.pathExtension, "jpg")
        XCTAssertEqual(OpenPushAttachmentLoader.stagedFile(
            for: URL(string: "https://cdn.example.com/media/42")!, downloadedFile: staged(png),
            response: URLResponse(url: URL(string: "https://cdn.example.com/media/42")!,
                                  mimeType: "image/jpeg", expectedContentLength: png.count,
                                  textEncodingName: nil),
            error: nil, options: .init())?.pathExtension, "jpg")
    }

    func testTheStagedFileIsNamespacedInTheTemporaryDirectory() throws {
        let file = try XCTUnwrap(OpenPushAttachmentLoader.stagedFile(
            for: URL(string: "https://cdn.example.com/a.png")!, downloadedFile: staged(png),
            response: URLResponse(url: URL(string: "https://cdn.example.com/a.png")!,
                                  mimeType: "image/png", expectedContentLength: png.count,
                                  textEncodingName: nil),
            error: nil, options: .init()))
        XCTAssertTrue(file.lastPathComponent.hasPrefix("openpush-"))
        XCTAssertEqual(file.pathExtension, "png")
        XCTAssertEqual(file.deletingLastPathComponent().standardizedFileURL,
                       FileManager.default.temporaryDirectory.standardizedFileURL)
        try? FileManager.default.removeItem(at: file)
    }

    // MARK: - Failure paths

    func testATransportErrorFailsOpen() {
        let recorder = Recorder()
        load("https://cdn.example.com/a.png", recorder: recorder,
             download: download(recorder, data: nil, mime: nil,
                                error: URLError(.timedOut)))

        XCTAssertEqual(recorder.downloads(), 1)
        XCTAssertEqual(recorder.completions(), 1, "every failure path completes exactly once")
        XCTAssertNil(recorder.attachment())
    }

    func testAnEmptyBodyIsRefused() {
        let recorder = Recorder()
        load("https://cdn.example.com/a.png", recorder: recorder,
             download: download(recorder, data: Data(), mime: "image/png"))

        XCTAssertEqual(recorder.completions(), 1)
        XCTAssertNil(recorder.attachment())
    }

    func testAnErrorStatusIsRefused() {
        let recorder = Recorder()
        let url = URL(string: "https://cdn.example.com/a.png")!
        let body = png
        let file = staged(body)
        let failing: OpenPushAttachmentLoader.Download = { request, completion in
            recorder.record(request)
            completion(file, HTTPURLResponse(url: url, statusCode: 404,
                                             httpVersion: nil, headerFields: nil), nil)
        }
        load("https://cdn.example.com/a.png", recorder: recorder, download: failing)

        XCTAssertEqual(recorder.completions(), 1)
        XCTAssertNil(recorder.attachment())
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
