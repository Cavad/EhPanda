import AppModels
import Clocks
import DownloadClient
import Foundation
import Synchronization
import Testing

/// The app-owned deadline on a page attempt's viewer stage.
///
/// A viewer request whose load never answers used to hold its page forever: the request's own
/// `timeoutInterval` is enforced only where URLSession performs the load, the image watchdog had no
/// transfer to watch, and every other page finished around it, leaving the row at N-1 of N with the
/// active badge. `NeverAnsweringURLProtocol` is that load, in the shape of a custom protocol with no
/// timeout of its own.
struct DownloadViewerDeadlineTests: DownloadFeatureTestCase {
    @Test(arguments: [false, true])
    func aViewerRequestThatNeverAnswersFailsOverAtTheDeadline(usesMPV: Bool) async throws {
        let hangingID = UUID().uuidString
        let recoveryID = UUID().uuidString
        let rootURL = FileManager.default.temporaryDirectory.appending(path: recoveryID, directoryHint: .isDirectory)
        defer { removeTemporaryItem(at: rootURL) }

        let viewer = try #require(URL(string: "https://e-hentai.org/s/012345abc0/123456-1"))
        let peer = try #require(URL(string: "https://peer-b.hath.network/\(recoveryID).gif"))
        let recoveryDispatches = LockedBox(0)

        let hangingConfiguration = URLSessionConfiguration.ephemeral
        hangingConfiguration.protocolClasses = [NeverAnsweringURLProtocol.self]
        hangingConfiguration.httpAdditionalHeaders = [NeverAnsweringURLProtocol.headerKey: hangingID]
        let hangingSession = URLSession(configuration: hangingConfiguration)
        let recoveryConfiguration = URLSessionConfiguration.ephemeral
        recoveryConfiguration.protocolClasses = [SharedSessionStubURLProtocol.self]
        recoveryConfiguration.httpAdditionalHeaders = [SharedSessionStubURLProtocol.headerKey: recoveryID]
        let recoverySession = URLSession(configuration: recoveryConfiguration)
        defer {
            hangingSession.invalidateAndCancel()
            recoverySession.invalidateAndCancel()
        }
        SharedSessionStubURLProtocol.setHandler(for: recoveryID) { request in
            let url = try #require(request.url)
            recoveryDispatches.value += 1
            if url.path == viewer.path {
                let html = """
                    <html><body>
                    <div id='i3'><img src='\(peer.absoluteString)'></div>
                    <div id='i6'><a id='loadfail' onclick="return nl('peer-token')">Retry</a></div>
                    </body></html>
                    """
                return (try makeResponse(url: url, contentType: "text/html"), Data(html.utf8))
            }
            let data = try JSONSerialization.data(withJSONObject: ["i": peer.absoluteString, "s": "peer-token"])
            return (try makeResponse(url: url, contentType: "application/json"), data)
        }
        defer { SharedSessionStubURLProtocol.removeHandler(for: recoveryID) }

        let imageBytes = try #require(Data(base64Encoded: "R0lGODlhAQABAIABAP///wAAACwAAAAAAQABAAACAkQBADs="))
        let downloader = DownloadPageDownloader { request, _, _ in
            let url = try #require(request.url)
            let fileURL = rootURL.appending(path: UUID().uuidString)
            try imageBytes.write(to: fileURL)
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/gif"]
            ))
            return .init(fileURL: fileURL, response: response)
        }
        let clock = TestClock()
        let storage = DownloadStore(rootURL: rootURL, fileManager: .default)
        try storage.ensureRootDirectory()
        let manager = DownloadCoordinator(
            storage: storage,
            urlSession: hangingSession,
            viewerRetrySession: recoverySession,
            pageDownloader: downloader,
            clock: clock
        )
        let payload = DownloadRequestPayload(
            gallery: sampleGallery(),
            galleryDetail: sampleGalleryDetail(gid: "123456", title: "Sample Gallery"),
            previewURLs: [:], previewConfig: .normal(rows: 4), host: .ehentai, folderName: "Folder", mode: .initial
        )
        let source: DownloadCoordinator.ResolvedSource =
            usesMPV ? .mpv(key: "mpv-key", imageKeys: [1: "012345abc0"]) : .normal([1: viewer])
        let context = DownloadCoordinator.PageDownloadContext(
            payload: payload,
            options: .init(autoRetryFailedPages: true),
            source: source,
            folderURL: rootURL
        )

        let wallClock = ContinuousClock()
        let start = wallClock.now
        let page = Task {
            try await manager.downloadPage(index: 1, context: context, preferredRelativePath: nil)
        }
        defer { page.cancel() }
        // The clock moves only until the hanging load is given up, so the recovery attempt's own,
        // longer deadline is never reached and its answer decides the page.
        try await waitUntil {
            if NeverAnsweringURLProtocol.wasStopped(hangingID) || recoveryDispatches.value > 0 { return true }
            await clock.advance(by: .seconds(30))
            return NeverAnsweringURLProtocol.wasStopped(hangingID) || recoveryDispatches.value > 0
        }
        let result = try await page.value
        // Well inside the request's own twenty-second interval: the app's deadline, not a
        // URLSession timeout of the custom protocol, is what gave the load up.
        #expect(wallClock.now - start < .seconds(10))

        #expect(result.imageURL == peer)
        #expect(try Data(contentsOf: rootURL.appending(path: result.relativePath)) == imageBytes)
        #expect(recoveryDispatches.value == 1)
        try await waitUntil({ NeverAnsweringURLProtocol.wasStopped(hangingID) })
    }

    /// The deadline returns even for an operation that does not honour its cancellation, so the
    /// page can move on without waiting for a load that never stops.
    @Test
    func theDeadlineReturnsWithoutWaitingForAnOperationThatIgnoresCancellation() async throws {
        let clock = TestClock()
        let operationFinished = LockedBox(false)
        let outcome = LockedBox<Result<Int, any Error>?>(nil)
        let call = Task {
            do {
                let value = try await DownloadCoordinator.testingWithPageStageDeadline(seconds: 30, clock: clock) {
                    await sleepIgnoringCancellation(for: .seconds(5))
                    operationFinished.value = true
                    return 1
                }
                outcome.value = .success(value)
            } catch {
                outcome.value = .failure(error)
            }
        }
        defer { call.cancel() }
        let wallClock = ContinuousClock()
        let start = wallClock.now
        try await waitUntil {
            if outcome.value != nil { return true }
            await clock.advance(by: .seconds(30))
            return outcome.value != nil
        }

        #expect(wallClock.now - start < .seconds(4))
        #expect(operationFinished.value == false)
        let result = try #require(outcome.value)
        #expect(throws: AppError.networkingFailed) {
            try result.get()
        }
    }

    @Test
    func theDeadlinePassesThroughAResultAndTheCallersCancellation() async throws {
        let clock = TestClock()
        let value = try await DownloadCoordinator.testingWithPageStageDeadline(seconds: 30, clock: clock) {
            7
        }
        #expect(value == 7)

        let entered = LockedBox(false)
        let cancelled = Task {
            try await DownloadCoordinator.testingWithPageStageDeadline(seconds: 30, clock: clock) {
                entered.value = true
                try await Task.sleep(for: .seconds(30))
                return 0
            }
        }
        try await waitUntil({ entered.value })
        cancelled.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }
    }
}

/// A load that never answers and records when it is stopped, keyed per test by a header.
final class NeverAnsweringURLProtocol: URLProtocol {
    static let headerKey = "X-NeverAnswering-ID"
    private static let stopped = Mutex(Set<String>())

    static func wasStopped(_ id: String) -> Bool {
        stopped.withLock({ $0.contains(id) })
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: headerKey) != nil
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {}

    override func stopLoading() {
        if let id = request.value(forHTTPHeaderField: Self.headerKey) {
            _ = Self.stopped.withLock({ $0.insert(id) })
        }
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }
}
