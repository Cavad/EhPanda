public import AppModels
import Foundation
import OSLogExt

private let logger = Logger(category: .init(describing: DownloadCoordinator.self))

// MARK: - Download Pages
extension DownloadCoordinator {
    private struct PageDownloadProgress {
        var results: [PageResult] = []
        var failedPages: [Int: PageFailure?] = [:]
        var pendingResolvedPages: [PageResult] = []
        var lastFlushDate: Date = Date()
    }

    private struct PageDownloadControl {
        var wasCancelled = false
        var didAbortForFatalError = false
    }

    private enum PageDownloadEvent: Sendable {
        case finished(index: Int, outcome: PageTaskOutcome)
        case slowPage(Int)
        case timerCancelled
    }

    private struct PageDownloadSchedule {
        var pending: ArraySlice<Int>
        let workerLimit: Int
        var activePages = Set<Int>()
        var slowPages = Set<Int>()
        var timers = [Int: Task<PageDownloadEvent, Never>]()

        var usesDelayedSecondSlot: Bool { workerLimit == 2 }

        mutating func nextPage() -> Int? {
            let capacity = usesDelayedSecondSlot && slowPages.isEmpty ? 1 : workerLimit
            guard activePages.count < capacity, let page = pending.popFirst() else { return nil }
            activePages.insert(page)
            return page
        }

        mutating func finished(_ page: Int) {
            activePages.remove(page)
            slowPages.remove(page)
            timers.removeValue(forKey: page)?.cancel()
        }
    }

    public func downloadPages(
        context: PageDownloadContext,
        pendingPageIndices: [Int],
        existingManifest: DownloadManifest,
        existingPageRelativePaths: [Int: String]
    ) async throws -> DownloadBatchResult {
        let existingPages = buildExistingPages(
            existingManifest: existingManifest,
            existingPageRelativePaths: existingPageRelativePaths
        )
        var progress = PageDownloadProgress()
        progress.failedPages = failedPageErrors[context.payload.gallery.gid]?
            .mapValues(Optional.some) ?? [:]

        try await initializePageDownloadState(
            context: context,
            existingPages: existingPages,
            progress: &progress
        )

        let restoredIndices = Set(progress.results.map(\.index))
        let remainingPageIndices = pendingPageIndices
            .filter({ !restoredIndices.contains($0) })
        var control = PageDownloadControl()
        await processRemainingPages(
            context: context,
            remainingPageIndices: remainingPageIndices,
            existingPages: existingPages,
            progress: &progress,
            control: &control
        )

        if control.wasCancelled || Task.isCancelled {
            throw CancellationError()
        }
        try await flushDownloadProgress(
            context: .init(
                gid: context.payload.gallery.gid,
                folderURL: context.folderURL
            ),
            pendingResolvedPages: &progress.pendingResolvedPages,
            lastFlushDate: &progress.lastFlushDate,
            force: true
        )
        return try buildBatchResult(
            results: progress.results,
            failedPages: progress.failedPages
        )
    }

    private func initializePageDownloadState(
        context: PageDownloadContext,
        existingPages: [Int: String],
        progress: inout PageDownloadProgress
    ) async throws {
        // G-15-14. The invariant is the whole class, not this site: no range in this module is
        // built from an unguarded page count. `makeInitialManifest` and `reusableExistingManifest`
        // already branch on the same value, so zero is a modeled input here too — and `1...0` is an
        // invalid ClosedRange that traps the process rather than failing the download. The empty
        // case is spelled as a conditional construction, in `makeInitialManifest`'s shape, rather
        // than an early return: the rest of this body then runs unchanged over an empty index list,
        // so no input reaches a different tail than it did before.
        let pageCount = context.payload.galleryDetail.pageCount
        let pageIndices = pageCount > 0 ? Array(1...pageCount) : []
        collectExistingPages(
            pageIndices: pageIndices,
            existingPages: existingPages,
            context: context,
            results: &progress.results,
            failedPages: &progress.failedPages
        )
        // The collection itself is the condition, and always was: the counter this used to read was
        // assigned `progress.results.count` on the line above and tested for positivity here, so it
        // never said anything the collection does not. Nothing read it afterwards — the batch result
        // is built from `progress.results`, and the manifest flush is handed the same collection —
        // which is what made the increment in `applyPageTaskOutcome` a pure dead write once 15-45
        // removed the last reader (G-15-29).
        guard progress.results.isEmpty == false else { return }
        try flushManifestPageProgress(
            folderURL: context.folderURL,
            pages: progress.results
        )
        await notifyObservers()
    }

    private func buildBatchResult(
        results: [PageResult],
        failedPages: [Int: PageFailure?]
    ) throws -> DownloadBatchResult {
        let activeFailedPages = failedPages.values
            .compactMap({ $0 })
            .filter {
                !isCancellationLikeAppError($0.error)
            }
            .sorted(by: { $0.index < $1.index })
        return .init(
            pages: results,
            failedPages: activeFailedPages
        )
    }

    private func buildExistingPages(
        existingManifest: DownloadManifest,
        existingPageRelativePaths: [Int: String]
    ) -> [Int: String] {
        let manifestPageIndices = Set(existingManifest.pages.keys)
        return existingPageRelativePaths.filter {
            manifestPageIndices.contains($0.key)
        }
    }

    private func collectExistingPages(
        pageIndices: [Int],
        existingPages: [Int: String],
        context: PageDownloadContext,
        results: inout [PageResult],
        failedPages: inout [Int: PageFailure?]
    ) {
        for page in pageIndices {
            guard let relativePath = existingPages[page] else {
                continue
            }
            let fileURL = context.folderURL
                .appending(path: relativePath)
            guard fileManager.operate({ $0.fileExists(atPath: fileURL.path(percentEncoded: false)) }) else {
                continue
            }
            failedPages[page] = nil
            results.append(
                .init(
                    index: page,
                    relativePath: relativePath,
                    imageURL: nil
                )
            )
        }
    }

    private func processRemainingPages(
        context: PageDownloadContext,
        remainingPageIndices: [Int],
        existingPages: [Int: String],
        progress: inout PageDownloadProgress,
        control: inout PageDownloadControl
    ) async {
        let gid = context.payload.gallery.gid
        await withTaskGroup(of: PageDownloadEvent.self) { group in
            var schedule = PageDownloadSchedule(
                pending: remainingPageIndices[...],
                workerLimit: context.options.workerCount
            )
            while !control.didAbortForFatalError, !control.wasCancelled {
                if Task.isCancelled || schedulingBlockedGalleryCounts[gid] != nil {
                    control.wasCancelled = true
                    break
                }
                while let page = schedule.nextPage() {
                    if schedule.usesDelayedSecondSlot, !schedule.pending.isEmpty {
                        let timer = Self.slowPageTimer(clock: clock, page: page)
                        schedule.timers[page] = timer
                        group.addTask {
                            await withTaskCancellationHandler {
                                await timer.value
                            } onCancel: {
                                timer.cancel()
                            }
                        }
                    }
                    let relativePath = existingPages[page]
                    group.addTask {
                        let outcome = await self.pageTaskOutcome(
                            page: page, context: context, preferredRelativePath: relativePath
                        )
                        return .finished(index: page, outcome: outcome)
                    }
                }
                guard let event = await group.next() else { break }
                if Task.isCancelled || schedulingBlockedGalleryCounts[gid] != nil {
                    control.wasCancelled = true
                    break
                }
                let outcome: PageTaskOutcome
                switch event {
                case .finished(let page, let result):
                    schedule.finished(page)
                    outcome = result
                case .slowPage(let page):
                    if schedule.activePages.contains(page) {
                        schedule.slowPages.insert(page)
                    }
                    continue
                case .timerCancelled:
                    continue
                }
                applyPageTaskOutcome(outcome, gid: gid, progress: &progress, control: &control)
                guard !control.wasCancelled, !control.didAbortForFatalError else { break }
                // A later forced flush persists the progress if this cadence flush fails.
                do {
                    try await flushDownloadProgress(
                        context: .init(gid: gid, folderURL: context.folderURL),
                        pendingResolvedPages: &progress.pendingResolvedPages,
                        lastFlushDate: &progress.lastFlushDate,
                        force: false
                    )
                } catch {
                    logger.error("Download progress cadence flush failed: \(error, privacy: .private)")
                }
            }
            group.cancelAll()
        }
    }

    // Take the deadline when scheduling the page. A quick completion cancels its timer; a
    // cancellation of the gallery cancels both the page transfer and its timer.
    private static func slowPageTimer(clock: some Clock<Duration>, page: Int) -> Task<PageDownloadEvent, Never> {
        let deadline = clock.now.advanced(by: .seconds(20))
        return Task {
            do {
                try await clock.sleep(until: deadline, tolerance: nil)
                return .slowPage(page)
            } catch {
                return .timerCancelled
            }
        }
    }

    private func applyPageTaskOutcome(
        _ outcome: PageTaskOutcome,
        gid: String,
        progress: inout PageDownloadProgress,
        control: inout PageDownloadControl
    ) {
        switch outcome {
        case .success(let pageResult):
            progress.failedPages[pageResult.index] = nil
            progress.results.append(pageResult)
            progress.pendingResolvedPages.append(pageResult)

        case .failure(let failure):
            if isCancellationLikeAppError(failure.error) {
                control.wasCancelled = true
                return
            }
            // The deliberate mover: a page that will not land in this run gives back its sub-page
            // credit. Deliberately after the cancellation-like return — a cancelled page is not a
            // failed one, and its credit is retired with the run instead.
            withdrawInFlightPageCredit(gid: gid, pageIndex: failure.index)
            progress.failedPages[failure.index] = failure
            control.didAbortForFatalError = isFatalAccountAppError(failure.error)

        case .cancelled:
            control.wasCancelled = true
        }
    }

    private func pageTaskOutcome(
        page: Int,
        context: PageDownloadContext,
        preferredRelativePath: String?
    ) async -> PageTaskOutcome {
        do {
            return .success(
                try await downloadPage(
                    index: page, context: context, preferredRelativePath: preferredRelativePath
                )
            )
        } catch is CancellationError {
            return .cancelled
        } catch let error as AppError {
            return .failure(.init(index: page, relativePath: preferredRelativePath, error: error))
        } catch {
            if Self.isCancellationLikeError(error) {
                return .cancelled
            }
            return .failure(.init(
                index: page, relativePath: preferredRelativePath,
                error: .fileOperationFailed(error.localizedDescription)
            ))
        }
    }

    /// Whether an error is account-level fatal and must abort the whole page batch.
    ///
    /// Scope is intentionally **account-level only**: limit, login, IP ban and an unsolved Cloudflare
    /// wall affect every in-flight and queued page, so continuing the batch only wastes requests and
    /// can worsen a ban.
    /// Gallery-level errors (`.expunged`, `.copyrightClaim`) are deliberately *not* fatal here — they
    /// mean the gallery is gone, but they surface before per-page download and are handled upstream,
    /// so a per-page occurrence is treated like any other page failure rather than aborting the batch.
    public func isFatalAccountAppError(_ error: AppError) -> Bool {
        switch error {
        // `.loginRejected` is unreachable from a page batch — it is thrown only by the login POST —
        // but it is account-level auth by the rule above, so it is classified with its neighbours
        // rather than defaulted. If a future path ever does surface it here, aborting the batch is
        // the safe reading: no page request succeeds while the credential is refused.
        case .imageLimitReached, .loginRequired, .ipBanned, .cloudflareChallengeFailed,
             .loginCaptchaRequired, .loginRejected:
            return true
        case .copyrightClaim, .expunged, .networkingFailed,
             .webImageFailed, .parseFailed, .fileOperationFailed, .noUpdates,
             .notFound, .unknown, .unsupportedDeepLink:
            return false
        }
    }
}
