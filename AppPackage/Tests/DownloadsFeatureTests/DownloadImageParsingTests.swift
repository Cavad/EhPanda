@testable import AppFeature
import AppModels
import AppTools
import ComposableArchitecture
import DownloadClient
import Foundation
import Testing
import TestingSupport

struct DownloadImageParsingTests: DownloadFeatureTestCase {
    @Test
    func defaultDownloadStartsASecondPageOnlyWhileAnotherPageIsSlow() async throws {
        let sessionID = UUID().uuidString
        let rootURL = FileManager.default.temporaryDirectory.appending(path: sessionID, directoryHint: .isDirectory)
        defer { removeTemporaryItem(at: rootURL) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SharedSessionStubURLProtocol.self]
        configuration.httpAdditionalHeaders = [SharedSessionStubURLProtocol.headerKey: sessionID]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        SharedSessionStubURLProtocol.setHandler(for: sessionID) { request in
            let url = try #require(request.url)
            let imageURL = "https://example.com/\(sessionID)/\(url.lastPathComponent).gif"
            let html = "<html><body><div id='i3'><img src='\(imageURL)'></div></body></html>"
            return (try makeResponse(url: url, contentType: "text/html"), Data(html.utf8))
        }
        defer { SharedSessionStubURLProtocol.removeHandler(for: sessionID) }

        let first = AsyncStream<Void>.makeStream()
        let second = AsyncStream<Void>.makeStream()
        defer {
            first.continuation.finish()
            second.continuation.finish()
        }
        let started = LockedBox(Set<Int>())
        let clock = TestClock()
        let wallDate = Date().addingTimeInterval(3_600)
        let image = try #require(Data(base64Encoded: "R0lGODlhAQABAIABAP///wAAACwAAAAAAQABAAACAkQBADs="))
        let downloader = DownloadPageDownloader { request, context, _ in
            started.value.insert(context.pageIndex)
            if context.pageIndex == 1 {
                for await _ in first.stream {}
            } else if context.pageIndex == 2 {
                for await _ in second.stream {}
            }
            try Task.checkCancellation()
            let url = try #require(request.url)
            let response = try makeResponse(url: url, contentType: "image/gif")
            let fileURL = rootURL.appending(path: UUID().uuidString)
            try image.write(to: fileURL)
            return .init(fileURL: fileURL, response: response)
        }
        let gallery = sampleGallery()
        let storage = DownloadStore(rootURL: rootURL, fileManager: .default)
        let manager = DownloadCoordinator(
            storage: storage, urlSession: session, pageDownloader: downloader,
            now: { wallDate }, clock: clock
        )
        let payload = DownloadRequestPayload(
            gallery: gallery,
            galleryDetail: sampleGalleryDetail(gid: gallery.gid, title: gallery.title),
            previewURLs: [:], previewConfig: .normal(rows: 4), host: .ehentai, folderName: "Folder", mode: .initial
        )
        let folderURL = storage.folderURL(relativePath: "Folder/[\(gallery.gid)_token] Sample")
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let manifest = try sampleManifest(gid: gallery.gid, title: gallery.title, pageCount: 3)
        try storage.writeManifest(manifest, folderURL: folderURL)
        let thumbnails = try Dictionary(uniqueKeysWithValues: (1...3).map { page in
            (page, try #require(URL(string: "https://e-hentai.org/s/test/\(gallery.gid)-\(page)")))
        })
        let operation = Task {
            try await manager.downloadPages(
                context: .init(payload: payload, options: .init(), source: .normal(thumbnails), folderURL: folderURL),
                pendingPageIndices: [1, 2, 3], existingManifest: manifest, existingPageRelativePaths: [:]
            )
        }
        defer { operation.cancel() }

        try await waitUntil({ started.value.contains(1) })
        await clock.advance(by: .zero)
        await clock.advance(by: .seconds(19))
        #expect(started.value == [1])
        await clock.advance(by: .seconds(1))
        try await waitUntil({ started.value.contains(2) })
        await clock.advance(by: .zero)
        #expect(started.value == [1, 2])

        first.continuation.finish()
        try await waitUntil {
            do {
                return try storage.readManifest(folderURL: folderURL).pages[1]?.isEmpty == false
            } catch {
                return false
            }
        }
        await clock.advance(by: .seconds(19))
        #expect(started.value == [1, 2])
        await clock.advance(by: .seconds(1))
        try await waitUntil({ started.value.contains(3) })

        second.continuation.finish()
        let result = try await operation.value
        #expect(result.failedPages.isEmpty)
        #expect(result.pages.map(\.index).sorted() == [1, 2, 3])
    }

    @Test
    func testFileBasedLimitImageMapsToImageLimitReached() async throws {
        let fileURL = try writeFixtureToTemporaryFile(filename: .bandwidthExceeded)
        defer { removeTemporaryItem(at: fileURL) }

        let manager = makeTestingDownloadCoordinator()
        let limitImageURL = try #require(URL(string: "https://ehgt.org/g/509.gif"))
        let response = try makeResponse(
            url: limitImageURL,
            contentType: "image/gif",
            contentLength: 28658
        )
        let error = await manager.detectResponseError(
            fileURL: fileURL,
            response: response,
            requestURL: limitImageURL
        )

        #expect(error == .imageLimitReached)
    }

    @Test
    func testFileBasedLimitImageRequiresKnown509Signature() async throws {
        let fileURL = try writeFixtureToTemporaryFile(filename: .bandwidthExceeded)
        defer { removeTemporaryItem(at: fileURL) }

        let manager = makeTestingDownloadCoordinator()
        var data = try Data(contentsOf: fileURL)
        data[0] = 0
        try data.write(to: fileURL, options: .atomic)
        let limitImageURL = try #require(URL(string: "https://ehgt.org/g/509.gif"))
        let response = try makeResponse(
            url: limitImageURL,
            contentType: "image/gif",
            contentLength: data.count
        )
        let error = await manager.detectResponseError(
            fileURL: fileURL,
            response: response,
            requestURL: limitImageURL
        )

        #expect(error == nil)
    }

    @Test
    func testFileBasedBinaryKokomadeImageMapsToLoginRequired() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appendingPathExtension("gif")
        defer { removeTemporaryItem(at: fileURL) }

        let imageData = try #require(Data(base64Encoded: "R0lGODlhAQABAIABAP///wAAACwAAAAAAQABAAACAkQBADs="))
        try imageData.write(to: fileURL, options: .atomic)

        let manager = makeTestingDownloadCoordinator()
        let kokomadeURL = try #require(URL(string: "https://exhentai.org/img/kokomade.jpg"))
        let response = try makeResponse(
            url: kokomadeURL,
            contentType: "image/gif",
            contentLength: imageData.count
        )
        let error = await manager.detectResponseError(
            fileURL: fileURL,
            response: response,
            requestURL: URL(string: "https://exhentai.org/fullimg.php?gid=1&page=1")
        )

        #expect(error == .loginRequired)
    }

    @Test
    func testFileBasedLimitImageFingerprintMapsToImageLimitReachedEvenWhenURLLooksNormal() async throws {
        let fileURL = try writeFixtureToTemporaryFile(filename: .bandwidthExceeded)
        defer { removeTemporaryItem(at: fileURL) }

        let manager = makeTestingDownloadCoordinator()
        let normalImageURL = try #require(URL(string: "https://ehgt.org/h/normal-image-cache-key/1"))
        let response = try makeResponse(
            url: normalImageURL,
            contentType: "image/gif",
            contentLength: 28658
        )
        let error = await manager.detectResponseError(
            fileURL: fileURL,
            response: response,
            requestURL: normalImageURL
        )

        #expect(error == .imageLimitReached)
    }

    @Test
    func testFileBasedKokomadeImageFingerprintMapsToLoginRequiredEvenWhenURLLooksNormal() async throws {
        let fileURL = try writeFixtureToTemporaryFile(resource: "Kokomade", pathExtension: "jpg")
        defer { removeTemporaryItem(at: fileURL) }

        let manager = makeTestingDownloadCoordinator()
        let normalImageURL = try #require(
            URL(string: "https://exhentai.org/fullimg.php?gid=1&page=1&key=normal-cache-key")
        )
        let error = await manager.detectResponseError(
            fileURL: fileURL,
            response: try makeResponse(
                url: normalImageURL,
                contentType: "image/jpeg",
                contentLength: 144844
            ),
            requestURL: normalImageURL
        )

        #expect(error == .loginRequired)
    }

    @Test
    func testFileBasedTextImageLimitMapsToImageLimitReached() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appendingPathExtension("html")
        defer { removeTemporaryItem(at: fileURL) }

        let htmlData = Data("""
        <html><body>You have exceeded your image viewing limits</body></html>
        """.utf8)
        try htmlData.write(to: fileURL, options: .atomic)

        let manager = makeTestingDownloadCoordinator()
        let limitURL = try #require(URL(string: "https://e-hentai.org/s/1/1-1"))
        let response = try makeResponse(
            url: limitURL,
            contentType: "text/html"
        )
        let error = await manager.detectResponseError(
            fileURL: fileURL,
            response: response,
            requestURL: limitURL
        )

        #expect(error == .imageLimitReached)
    }

    @Test
    func testFatalAccountPageFailureStopsSchedulingRemainingPages() async throws {
        let sessionID = UUID().uuidString
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { removeTemporaryItem(at: rootURL) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SharedSessionStubURLProtocol.self]
        configuration.httpAdditionalHeaders = [
            SharedSessionStubURLProtocol.headerKey: sessionID
        ]
        let storage = DownloadStore(rootURL: rootURL, fileManager: .default)
        let manager = DownloadCoordinator(
            storage: storage,
            urlSession: URLSession(configuration: configuration)
        )
        let recorder = RequestRecorder()
        let limitHTML = Data("""
        <html><body>You have exceeded your image viewing limits</body></html>
        """.utf8)
        SharedSessionStubURLProtocol.setHandler(for: sessionID) { request in
            recorder.recordImageDownload()
            return (
                try #require(HTTPURLResponse(
                    url: request.url ?? Defaults.URL.ehentai,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/html"]
                )),
                limitHTML
            )
        }
        defer {
            SharedSessionStubURLProtocol.removeHandler(for: sessionID)
        }

        var gallery = sampleGallery()
        gallery.pageCount = 3
        var detail = sampleGalleryDetail(gid: gallery.gid, title: gallery.title)
        detail.pageCount = 3
        var options = DownloadRequestOptions()
        options.threadLimit = 1
        options.autoRetryFailedPages = false
        let payload = DownloadRequestPayload(
            gallery: gallery,
            galleryDetail: detail,
            previewURLs: [:],
            previewConfig: .normal(rows: 4),
            host: .ehentai,
            folderName: "Folder",
            mode: .initial
        )
        let galleryFolderName = storage.makeFolderRelativePath(
            gid: gallery.gid,
            token: gallery.token,
            title: detail.trimmedTitle
        )
        let folderURL = storage.folderURL(
            relativePath: "Folder/\(galleryFolderName)"
        )
        try FileManager.default.createDirectory(
            at: folderURL,
            withIntermediateDirectories: true
        )
        let manifest = try sampleManifest(
            gid: gallery.gid,
            title: gallery.title,
            pageCount: detail.pageCount
        )
        let batchResult = try await manager.downloadPages(
            context: .init(
                payload: payload,
                options: options,
                source: .normal([
                    1: try #require(URL(string: "https://example.com/1.html")),
                    2: try #require(URL(string: "https://example.com/2.html")),
                    3: try #require(URL(string: "https://example.com/3.html"))
                ]),
                folderURL: folderURL
            ),
            pendingPageIndices: [1, 2, 3],
            existingManifest: manifest,
            existingPageRelativePaths: [:]
        )

        #expect(batchResult.failedPages.map(\.index) == [1])
        #expect(batchResult.failedPages.first?.error == .imageLimitReached)
        #expect(recorder.snapshot().imageDownloads == 1)
    }

    @Test
    func testCachedLimitPlaceholderStoredUnderNormalImageURLIsRejected() async throws {
        try await expectCachedPlaceholderRejected(
            url: try #require(
                URL(string: "https://ehgt.org/h/image-limit-placeholder-cache-\(UUID().uuidString)/1")
            ),
            placeholderData: try fixtureData(filename: .bandwidthExceeded)
        )
    }

    enum ImageRetryScenario: CaseIterable {
        case disabled
        case bothPeersFail
        case viewerReloadTimesOut
    }

    @Test(arguments: [false, true], ImageRetryScenario.allCases)
    func pageDownloadRetriesViewerAndImageFailures(usesMPV: Bool, scenario: ImageRetryScenario) async throws {
        let sessionID = UUID().uuidString
        let recoveryID = UUID().uuidString
        let rootURL = FileManager.default.temporaryDirectory.appending(path: sessionID, directoryHint: .isDirectory)
        defer { removeTemporaryItem(at: rootURL) }

        let viewer = try #require(URL(string: "https://e-hentai.org/s/012345abc0/123456-1"))
        let peerA = try #require(URL(string: "https://peer-a.hath.network/\(sessionID).gif"))
        let peerB = try #require(URL(string: "https://peer-b.hath.network/\(sessionID).gif"))
        let origin = try #require(URL(string: "https://ehgt.org/\(sessionID).gif"))
        let transfers = LockedBox([URL]())
        let dispatches = LockedBox([String?]())

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SharedSessionStubURLProtocol.self]
        configuration.httpAdditionalHeaders = [SharedSessionStubURLProtocol.headerKey: sessionID]
        let session = URLSession(configuration: configuration)
        configuration.httpAdditionalHeaders = [SharedSessionStubURLProtocol.headerKey: recoveryID]
        let recoverySession = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            recoverySession.invalidateAndCancel()
        }
        let respond: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            let url = try #require(request.url)
            let onRecoverySession = request.value(forHTTPHeaderField: SharedSessionStubURLProtocol.headerKey)
                == recoveryID
            #expect(request.timeoutInterval == (onRecoverySession ? 30 : 20))
            let isNormalViewer = url.path == viewer.path
            let skip = if isNormalViewer {
                URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                    .first(where: { $0.name == "nl" })?.value
            } else {
                requestBodyJSONObject(from: request)?["nl"] as? String
            }
            dispatches.value.append(skip)
            if scenario == .viewerReloadTimesOut && skip == "peer-token" && !onRecoverySession {
                throw URLError(.timedOut)
            }
            if scenario == .viewerReloadTimesOut && dispatches.value.count == 3 {
                #expect(onRecoverySession)
            }
            if url.path == viewer.path {
                #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
                let imageURL: URL
                switch skip {
                case "1":
                    imageURL = origin
                case "peer-token":
                    imageURL = peerB
                default:
                    imageURL = peerA
                }
                let html = """
                    <html><body>
                    <div id='i3'><img src='\(imageURL.absoluteString)'></div>
                    <div id='i6'><a id='loadfail' onclick="return nl('peer-token')">Retry</a></div>
                    </body></html>
                    """
                return (try makeResponse(url: url, contentType: "text/html"), Data(html.utf8))
            }
            #expect(usesMPV)
            #expect(url == Defaults.URL.api(host: .ehentai))
            let imageURL = skip == nil ? peerA : peerB
            let data = try JSONSerialization.data(withJSONObject: ["i": imageURL.absoluteString, "s": "peer-token"])
            return (try makeResponse(url: url, contentType: "application/json"), data)
        }
        SharedSessionStubURLProtocol.setHandler(for: sessionID, handler: respond)
        SharedSessionStubURLProtocol.setHandler(for: recoveryID, handler: respond)
        defer {
            SharedSessionStubURLProtocol.removeHandler(for: sessionID)
            SharedSessionStubURLProtocol.removeHandler(for: recoveryID)
        }

        let imageBytes = try #require(Data(base64Encoded: "R0lGODlhAQABAIABAP///wAAACwAAAAAAQABAAACAkQBADs="))
        let downloader = DownloadPageDownloader { request, _, _ in
            let url = try #require(request.url)
            transfers.value.append(url)
            if url == peerA { throw URLError(.cancelled) }
            let fileURL = rootURL.appending(path: UUID().uuidString)
            try imageBytes.write(to: fileURL)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: url == peerB && scenario == .bothPeersFail ? 502 : 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "image/gif"]
            ))
            return .init(fileURL: fileURL, response: response)
        }
        let storage = DownloadStore(rootURL: rootURL, fileManager: .default)
        try storage.ensureRootDirectory()
        let manager = DownloadCoordinator(
            storage: storage, urlSession: session, viewerRetrySession: recoverySession, pageDownloader: downloader
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
            options: .init(autoRetryFailedPages: scenario != .disabled),
            source: source,
            folderURL: rootURL
        )

        switch scenario {
        case .bothPeersFail:
            let result = try await manager.downloadPage(index: 1, context: context, preferredRelativePath: nil)
            #expect(result.imageURL == origin)
            #expect(try Data(contentsOf: rootURL.appending(path: result.relativePath)) == imageBytes)
            #expect(transfers.value == [peerA, peerB, origin])
            #expect(dispatches.value == [nil, "peer-token", nil, "1"])
        case .viewerReloadTimesOut:
            let result = try await manager.downloadPage(index: 1, context: context, preferredRelativePath: nil)
            #expect(result.imageURL == peerB)
            #expect(transfers.value == [peerA, peerB])
            #expect(dispatches.value == [nil, "peer-token", "peer-token"])
        case .disabled:
            await #expect(throws: AppError.networkingFailed) {
                try await manager.downloadPage(index: 1, context: context, preferredRelativePath: nil)
            }
            #expect(transfers.value == [peerA])
            #expect(dispatches.value == [nil])
        }
    }

    @Test
    func testMPVImageResolutionFailsOverWithSkipServerTokenOnRetry() async throws {
        let sessionID = UUID().uuidString
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { removeTemporaryItem(at: rootURL) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SharedSessionStubURLProtocol.self]
        configuration.httpAdditionalHeaders = [
            SharedSessionStubURLProtocol.headerKey: sessionID
        ]
        let storage = DownloadStore(rootURL: rootURL, fileManager: .default)
        let manager = DownloadCoordinator(
            storage: storage,
            urlSession: URLSession(configuration: configuration)
        )

        let receivedSkipServerTokens = LockedBox([String?]())
        SharedSessionStubURLProtocol.setHandler(for: sessionID) { request in
            let body = requestBodyJSONObject(from: request)
            let skipServer = body?["nl"] as? String
            receivedSkipServerTokens.value.append(skipServer)
            let imageURL = skipServer == nil
                ? "https://example.com/server-a.jpg"
                : "https://example.com/server-b.jpg"
            let dispatch = skipServer == nil ? ["i": imageURL, "s": "42"] : ["i": imageURL]
            let data = try JSONSerialization.data(withJSONObject: dispatch)
            return (
                try #require(HTTPURLResponse(
                    url: request.url ?? Defaults.URL.api(host: .ehentai),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )),
                data
            )
        }
        defer { SharedSessionStubURLProtocol.removeHandler(for: sessionID) }

        let payload = DownloadRequestPayload(
            gallery: sampleGallery(),
            galleryDetail: sampleGalleryDetail(gid: "123456", title: "Sample Gallery"),
            previewURLs: [:],
            previewConfig: .normal(rows: 4),
            host: .ehentai,
            folderName: "Folder",
            mode: .initial
        )
        let source = DownloadCoordinator.ResolvedSource.mpv(key: "mpvkey", imageKeys: [1: "imgkey1"])

        let first = try await manager.resolvedImageSource(
            index: 1, payload: payload, options: .init(), source: source, failover: nil
        )
        let second = try await manager.resolvedImageSource(
            index: 1, payload: payload, options: .init(), source: source, failover: first
        )

        #expect(receivedSkipServerTokens.value == [nil, "42"])
        #expect(first.imageURL.absoluteString == "https://example.com/server-a.jpg")
        #expect(first.skipServerIdentifier == "42")
        #expect(second.imageURL.absoluteString == "https://example.com/server-b.jpg")
        #expect(second.skipServerIdentifier == nil)
    }

}
