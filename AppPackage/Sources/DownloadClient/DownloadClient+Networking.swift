import AnimatedImageFeature
import AppModels
public import Foundation
import OSLogExt
import UniformTypeIdentifiers

private let logger = Logger(category: .init(describing: DownloadCoordinator.self))

// MARK: - Network
extension DownloadCoordinator {
    public func downloadResponse(
        url: URL,
        allowsCellular: Bool,
        retriesRequest: Bool = true
    ) async throws -> (fileURL: URL, response: URLResponse) {
        var request = URLRequest(url: url)
        request.allowsCellularAccess = allowsCellular
        return try await downloadResponse(
            for: request,
            retriesRequest: retriesRequest
        )
    }

    public func downloadResponse(
        for request: URLRequest,
        retriesRequest: Bool = true
    ) async throws -> (fileURL: URL, response: URLResponse) {
        let performRequest = {
            try await self.rawDownloadResponse(for: request)
        }

        let response: (fileURL: URL, response: URLResponse)
        if retriesRequest {
            response = try await withRetry(
                operation: "downloadResponse"
            ) {
                try await performRequest()
            }
        } else {
            response = try await performRequest()
        }

        if let error = detectResponseError(
            fileURL: response.fileURL,
            response: response.response,
            requestURL: request.url
        ) {
            discardRejectedResponseFile(at: response.fileURL)
            throw error
        }

        return response
    }

    public func rawDownloadResponse(
        for request: URLRequest
    ) async throws -> (fileURL: URL, response: URLResponse) {
        do {
            return try await urlSession.download(for: request)
        } catch let error as AppError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError
                    where error.code == .cancelled {
            throw CancellationError()
        } catch {
            if Self.isCancellationLikeError(error) {
                throw CancellationError()
            }
            if error is URLError {
                throw AppError.networkingFailed
            }
            throw AppError.unknown
        }
    }

    public func pageDownloadResponse(
        url: URL,
        allowsCellular: Bool,
        context: DownloadPageTaskContext,
        retriesRequest: Bool = true
    ) async throws -> DownloadPageTransfer {
        var request = URLRequest(url: url)
        request.allowsCellularAccess = allowsCellular
        return try await pageDownloadResponse(
            for: request,
            context: context,
            retriesRequest: retriesRequest
        )
    }

    public func pageDownloadResponse(
        for request: URLRequest,
        context: DownloadPageTaskContext,
        retriesRequest: Bool = true
    ) async throws -> DownloadPageTransfer {
        let performRequest = {
            try await self.rawPageDownloadResponse(
                for: request,
                context: context
            )
        }

        let transfer: DownloadPageTransfer
        if retriesRequest {
            transfer = try await withRetry(
                operation: "pageDownloadResponse"
            ) {
                try await performRequest()
            }
        } else {
            transfer = try await performRequest()
        }

        let responseError = detectResponseError(
            fileURL: transfer.fileURL,
            response: transfer.response,
            requestURL: request.url
        )
        let httpResponse = transfer.response as? HTTPURLResponse
        let isHTTPSuccess = httpResponse.map({ (200..<300).contains($0.statusCode) }) == true
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["EHPANDA_DOWNLOAD_DIAGNOSIS"] == "1" {
            let status = httpResponse?.statusCode ?? 0
            let expected = transfer.response.expectedContentLength
            let page = context.pageIndex
            logger.notice("DL_DIAG response page=\(page) http=\(status) expected_bytes=\(expected)")
        }
        #endif
        if let error = responseError ?? (isHTTPSuccess ? nil : .networkingFailed) {
            discardRejectedResponseFile(at: transfer.fileURL)
            if let taskIdentifier = transfer.taskIdentifier {
                await backgroundTaskStore.remove(taskIdentifier: taskIdentifier)
            }
            throw error
        }

        return transfer
    }

    public func rawPageDownloadResponse(
        for request: URLRequest,
        context: DownloadPageTaskContext
    ) async throws -> DownloadPageTransfer {
        // The in-flight entry brackets the transfer itself rather than the retry loop above it, so
        // each attempt measures its own time to first byte while the page's earned credit carries
        // across attempts. The `defer` covers the throwing exits too, which is what lets a transfer
        // cancelled by the expiry's pause sweep still report how long it starved.
        //
        // The downloader owns the URLSession task. Both the idle watchdog and the heartbeat
        // stop it through this attempt's cancellation handle. The cancellation handler also
        // forwards a pause or cancellation of the gallery's worker.
        //
        // An abandoned attempt surfaces as the retryable `AppError.networkingFailed`, never as
        // `CancellationError`, so `downloadPage`'s attempts loop retries the page with a fresh
        // failover re-resolution rather than propagating a stop the user never asked for.
        let attemptID = beginPageTransfer(gid: context.gid, pageIndex: context.pageIndex)
        let pageDownloader = self.pageDownloader
        let attempt = Task { [pageDownloader, weak self] in
            try await pageDownloader.download(request, context) { [weak self] written, expected in
                Task {
                    await self?.recordPageTransferBytes(
                        gid: context.gid,
                        pageIndex: context.pageIndex,
                        bytesWritten: written,
                        bytesExpected: expected,
                        attemptID: attemptID
                    )
                }
            }
        }
        attachPageTransferAttempt(
            gid: context.gid,
            pageIndex: context.pageIndex,
            attempt
        )
        let watchdog = Task {
            await watchPageTransfer(gid: context.gid, pageIndex: context.pageIndex, attemptID: attemptID)
        }
        defer {
            watchdog.cancel()
            endPageTransfer(gid: context.gid, pageIndex: context.pageIndex)
        }
        do {
            return try await withTaskCancellationHandler {
                try await attempt.value
            } onCancel: {
                attempt.cancel()
            }
        } catch {
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.environment["EHPANDA_DOWNLOAD_DIAGNOSIS"] == "1" {
                let nsError = error as NSError
                let isURL = nsError.domain == NSURLErrorDomain
                logger.notice("DL_DIAG transfer_error page=\(context.pageIndex) url_error=\(isURL) code=\(nsError.code)")
            }
            #endif
            // A pause or group cancellation cancels this parent task. A URLSession or watchdog
            // cancellation while the parent is active belongs to one page and can be retried.
            try Task.checkCancellation()
            if let error = error as? AppError {
                throw error
            }
            if error is URLError || Self.isCancellationLikeError(error) {
                throw AppError.networkingFailed
            }
            throw AppError.unknown
        }
    }

    public func withRetry<T>(
        operation: String,
        maxAttempts: Int = retryLimit,
        body: () async throws -> T
    ) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await body()
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as AppError {
                guard error.isRetryable,
                      attempt < maxAttempts else {
                    throw error
                }
                logger.warning(
                    """
                    Download operation will retry, operation: \(operation, privacy: .public), \
                    attempt: \(attempt, privacy: .public), \
                    error: \(error.localizedDescription, privacy: .private)
                    """
                )
                attempt += 1
            } catch {
                guard attempt < maxAttempts else {
                    throw error
                }
                logger.warning(
                    """
                    Download operation will retry after unexpected error, \
                    operation: \(operation, privacy: .public), \
                    attempt: \(attempt, privacy: .public), \
                    error: \(error.localizedDescription, privacy: .private)
                    """
                )
                attempt += 1
            }
        }
    }
}

// MARK: - File Operations
extension DownloadCoordinator {
    public func fileExtension(
        for url: URL,
        response: URLResponse?,
        prefixData: Data
    ) -> String {
        if !url.pathExtension.isEmpty {
            return url.pathExtension.lowercased()
        }
        if let ext = extensionFromMimeType(response) {
            return ext
        }
        return prefixData.knownBinaryImageFileExtension ?? "jpg"
    }

    private func extensionFromMimeType(
        _ response: URLResponse?
    ) -> String? {
        guard let mimeType = response?.mimeType?.lowercased()
        else {
            return nil
        }
        switch mimeType {
        case "image/jpeg":
            return "jpg"
        case "image/png":
            return "png"
        case "image/gif":
            return "gif"
        case "image/webp":
            return "webp"
        default:
            guard mimeType.hasPrefix("image/") else { return nil }
            return UTType(mimeType: mimeType)?.preferredFilenameExtension
        }
    }

    public func createDirectory(at url: URL) throws {
        try fileManager.operate {
            try $0.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        }
    }

    public func write(data: Data, to url: URL) throws {
        try createDirectory(at: url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
    }

    public func moveDownloadedFile(
        from sourceURL: URL,
        to destinationURL: URL
    ) throws {
        try createDirectory(
            at: destinationURL.deletingLastPathComponent()
        )
        if fileManager.operate({ $0.fileExists(atPath: destinationURL.path(percentEncoded: false)) }) {
            try fileManager.operate {
                try $0.removeItem(at: destinationURL)
            }
        }
        try fileManager.operate {
            try $0.moveItem(at: sourceURL, to: destinationURL)
        }
    }

    public func readResponsePrefixData(at fileURL: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: fileURL)
        // Closing is best-effort during defer; any read/open error remains the
        // operation's primary failure and the handle is also closed on deallocation.
        defer { storage.closeReadHandle(handle) }
        return try handle.read(
            upToCount: Self.responseInspectionPrefixLength
        ) ?? Data()
    }

    /// Removes a downloaded file that response validation has just rejected. The rejection
    /// is already decided and its error is the authoritative failure the caller propagates,
    /// so an unexpected removal failure is logged rather than replacing that error.
    private func discardRejectedResponseFile(at fileURL: URL) {
        do {
            try fileManager.operate {
                try $0.removeItem(at: fileURL)
            }
        } catch {
            logger.error("Rejected download response removal failed: \(error, privacy: .private)")
        }
    }
}
