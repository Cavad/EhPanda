import AppModels
import AppTools
import Foundation
import NetworkingFeature
import OSLogExt
import ParserFeature

private let logger = Logger(category: .init(describing: DownloadCoordinator.self))
#if DEBUG && targetEnvironment(simulator)
private let diagnosisLogger = Logger(category: .init(describing: DownloadCoordinator.self))
#endif

// MARK: - Download Single Page
extension DownloadCoordinator {
    public func downloadPage(
        index: Int,
        context: PageDownloadContext,
        preferredRelativePath: String?
    ) async throws -> PageResult {
        guard let source = context.source else {
            throw AppError.notFound
        }
        let attempts = context.options.autoRetryFailedPages ? 4 : 1
        var capturedError: AppError = .unknown
        var failover: ResolvedImageSource?
        var didResolvePeerReload = false
        var retryingViewerConnection = false
        var failedImageURLs = Set<URL>()

        for attempt in 0..<attempts {
            try Task.checkCancellation()
            var attemptedImageURL: URL?
            #if DEBUG && targetEnvironment(simulator)
            let began = Date()
            #endif
            do {
                let resolved: ResolvedImageSource
                if attempt == 3 {
                    guard !failedImageURLs.isEmpty, Self.allowsMainSiteRetry(after: capturedError),
                          let mainSiteImage = try await resolveMainSiteImage(
                              page: index, context: context, source: source,
                              retryingViewerConnection: retryingViewerConnection
                          ),
                          !failedImageURLs.contains(mainSiteImage.imageURL)
                    else { break }
                    resolved = mainSiteImage
                } else {
                    let reload = didResolvePeerReload ? nil : failover
                    resolved = try await resolvedImageSource(
                        index: index,
                        payload: context.payload,
                        options: context.options,
                        source: source,
                        failover: reload,
                        retryingViewerConnection: retryingViewerConnection
                    )
                    // A viewer timeout has yet to resolve a new peer. Keep its reload token for
                    // another attempt. After a successful reload, use an ordinary dispatch.
                    if reload?.skipServerIdentifier != nil {
                        didResolvePeerReload = true
                    }
                }
                failover = resolved
                if let result = try await attemptResolvedCacheRestore(
                    index: index,
                    resolvedImageSource: resolved,
                    context: context,
                    preferredRelativePath: preferredRelativePath
                ) {
                    return result
                }
                // A fresh dispatch can hand out the exact same signed URL. Move on to another
                // route without waiting for that transfer to time out again.
                guard !failedImageURLs.contains(resolved.imageURL) else { continue }
                attemptedImageURL = resolved.imageURL
                #if DEBUG && targetEnvironment(simulator)
                if ProcessInfo.processInfo.environment["EHPANDA_DOWNLOAD_DIAGNOSIS"] == "1" {
                    let port = resolved.imageURL.port ?? 443
                    let peer = resolved.imageURL.host()?.hasSuffix(".hath.network") ?? false
                    diagnosisLogger.notice(
                        "DL_DIAG resolved page=\(index) attempt=\(attempt) port=\(port) peer=\(peer)"
                    )
                }
                #endif
                return try await downloadAndSavePage(
                    index: index,
                    resolvedImageSource: resolved,
                    context: context,
                    preferredRelativePath: preferredRelativePath
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as AppError {
                try Task.checkCancellation()
                capturedError = error
                retryingViewerConnection = attemptedImageURL == nil && error == .networkingFailed
                let stage = attemptedImageURL == nil ? "viewer" : "image"
                let failureCode = DownloadFailure(error: error).code.rawValue
                logger.notice(
                    """
                    Download page attempt failed, page: \(index, privacy: .public), \
                    attempt: \(attempt + 1, privacy: .public), stage: \(stage, privacy: .public), \
                    code: \(failureCode, privacy: .public)
                    """
                )
                #if DEBUG && targetEnvironment(simulator)
                if ProcessInfo.processInfo.environment["EHPANDA_DOWNLOAD_DIAGNOSIS"] == "1" {
                    let stage = attemptedImageURL == nil ? "viewer" : "transfer_or_save"
                    let code = DownloadFailure(error: error).code.rawValue
                    let seconds = Int(Date().timeIntervalSince(began))
                    diagnosisLogger.notice(
                        """
                        DL_DIAG attempt_failed page=\(index) attempt=\(attempt) stage=\(stage, privacy: .public) \
                        code=\(code, privacy: .public) seconds=\(seconds)
                        """
                    )
                }
                #endif
                if let attemptedImageURL {
                    failedImageURLs.insert(attemptedImageURL)
                }
                // An image-node 404 can mean an expired URL. A missing viewer page or an
                // account-level error still surfaces immediately.
                guard error.isRetryable || (error == .notFound && attemptedImageURL != nil) else { throw error }
            } catch {
                if Self.isCancellationLikeError(error) {
                    throw CancellationError()
                }
                throw error
            }
        }

        throw capturedError
    }

    private static func allowsMainSiteRetry(after error: AppError) -> Bool {
        switch error {
        case .networkingFailed, .notFound, .parseFailed, .webImageFailed:
            return true
        default:
            return false
        }
    }

    /// The single-page viewer supports a direct-delivery request for eligible accounts.
    /// Use the site's rendered image URL so the configured resolution and account limits apply.
    private func resolveMainSiteImage(
        page: Int, context: PageDownloadContext, source: ResolvedSource,
        retryingViewerConnection: Bool
    ) async throws -> ResolvedImageSource? {
        let payload = context.payload
        let viewerURL: URL
        switch source {
        case .normal(let thumbnails):
            guard let thumbnail = thumbnails[page],
                  let route = GalleryURLParser.parse(thumbnail),
                  route.isGalleryImageURL, route.gid == payload.gallery.gid, route.pageIndex == page
            else { return nil }
            viewerURL = route.url
        case .mpv(_, let imageKeys):
            guard let key = imageKeys[page], key.count == 10,
                  key.allSatisfy(\.isHexDigit),
                  payload.gallery.gid.isValidGID
            else { return nil }
            viewerURL = payload.host.url.appending(path: "s/\(key)/\(payload.gallery.gid)-\(page)")
        }

        let directViewerURL = imageViewerURL(viewerURL, skipServerIdentifier: "1")
        var request = GalleryNormalImageRequest(
            index: page, pageURL: directViewerURL,
            urlSession: retryingViewerConnection ? viewerRetrySession : urlSession,
            allowsCellular: context.options.allowCellular, attempts: 1
        )
        request.timeoutInterval = retryingViewerConnection ? 30 : 20
        request.reloadsImageLink = true
        let imageURL = try await request.response().imageURL
        guard imageURL.scheme == "https", imageURL.host() != nil else { return nil }
        return .init(imageURL: imageURL)
    }

    private func attemptResolvedCacheRestore(
        index: Int,
        resolvedImageSource: ResolvedImageSource,
        context: PageDownloadContext,
        preferredRelativePath: String?
    ) async throws -> PageResult? {
        let payload = context.payload
        let resolvedCacheURLs = pageImageCacheURLs(
            imageURL: resolvedImageSource.imageURL
        )
        let resolvedSource = CacheRestoreSource(
            gid: payload.gallery.gid,
            token: payload.gallery.token,
            cacheURLs: resolvedCacheURLs,
            referenceURL: preferredPageReferenceURL(
                resolvedImageSource: resolvedImageSource
            ),
            imageURL: resolvedImageSource.imageURL
        )
        return try await restorePageFromCache(
            index: index,
            source: resolvedSource,
            folderURL: context.folderURL,
            preferredRelativePath: preferredRelativePath
        )
    }

    private func downloadAndSavePage(
        index: Int,
        resolvedImageSource: ResolvedImageSource,
        context: PageDownloadContext,
        preferredRelativePath: String?
    ) async throws -> PageResult {
        let payload = context.payload
        let targetURL = resolvedImageSource.imageURL
        let transfer =
            try await pageDownloadResponse(
                url: targetURL,
                allowsCellular: context.options.allowCellular,
                context: .init(
                    gid: payload.gallery.gid,
                    pageIndex: index
                ),
                retriesRequest: false
            )
        let relativePath: String
        if let preferredRelativePath {
            relativePath = preferredRelativePath
        } else {
            let prefixData = try readResponsePrefixData(
                at: transfer.fileURL
            )
            let ext = fileExtension(
                for: targetURL,
                response: transfer.response,
                prefixData: prefixData
            )
            relativePath = storage.makePageRelativePath(
                gid: payload.gallery.gid,
                token: payload.gallery.token,
                index: index,
                fileExtension: ext
            )
        }
        let fileURL = context.folderURL
            .appending(path: relativePath)
        do {
            try moveDownloadedFile(
                from: transfer.fileURL,
                to: fileURL
            )
            if let taskIdentifier = transfer.taskIdentifier {
                await backgroundTaskStore.remove(taskIdentifier: taskIdentifier)
            }
        } catch {
            // The move never consumed the staged file; drop it unconditionally so it
            // can't strand, matching the sibling failure paths.
            removeStagedBackgroundFile(transfer.fileURL)
            if let taskIdentifier = transfer.taskIdentifier {
                await backgroundTaskStore.remove(taskIdentifier: taskIdentifier)
            }
            throw error
        }
        return .init(
            index: index,
            relativePath: relativePath,
            imageURL: resolvedImageSource.imageURL
        )
    }
}
