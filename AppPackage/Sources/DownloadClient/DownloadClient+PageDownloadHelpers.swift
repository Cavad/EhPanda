import AppModels
import AppTools
import Foundation
import NetworkingFeature

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
        let attempts = context.options.autoRetryFailedPages ? 3 : 1
        var capturedError: AppError = .unknown
        var failover: ResolvedImageSource?
        var failedImageURLs = Set<URL>()

        for attempt in 0..<attempts {
            try Task.checkCancellation()
            var attemptedImageURL: URL?
            do {
                let resolved: ResolvedImageSource
                if attempt == 2 {
                    guard !failedImageURLs.isEmpty, Self.allowsMainSiteRetry(after: capturedError),
                          let mainSiteImage = try await resolveMainSiteImage(
                              page: index, context: context, source: source
                          ),
                          !failedImageURLs.contains(mainSiteImage.imageURL)
                    else { break }
                    resolved = mainSiteImage
                } else {
                    resolved = try await resolvedImageSource(
                        index: index,
                        payload: context.payload,
                        options: context.options,
                        source: source,
                        failover: failover
                    )
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
                attemptedImageURL = resolved.imageURL
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
        page: Int, context: PageDownloadContext, source: ResolvedSource
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

        guard var components = URLComponents(url: viewerURL, resolvingAgainstBaseURL: false) else { return nil }
        let skipServerKey = Defaults.URL.Component.Key.skipServerIdentifier.rawValue
        let query = (components.queryItems ?? []).filter({ $0.name != skipServerKey })
        components.queryItems = query + [.init(name: skipServerKey, value: "1")]
        guard let directViewerURL = components.url else { return nil }

        let result = try await GalleryNormalImageURLsRequest(
            thumbnailURLs: [page: directViewerURL],
            urlSession: urlSession,
            allowsCellular: context.options.allowCellular,
            attempts: 1
        )
        .response()
        guard let imageURL = result.imageURLs[page], imageURL.scheme == "https", imageURL.host() != nil
        else { return nil }
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
