import AppModels
import Foundation
import Synchronization

// MARK: - Page Stage Deadline
extension DownloadCoordinator {
    /// The app's own bound on one viewer or dispatch request of a page attempt, on the session the
    /// attempt starts on.
    ///
    /// **Why the request's `timeoutInterval` is not enough.** URLSession treats it as an idle
    /// interval that every received packet resets, and it applies only where the loading system
    /// itself performs the load. A custom `URLProtocol` owns its own timeouts; the Laboratory's
    /// SNI-bypass protocol, which registers for the shared session, has none, and a stream of its
    /// that ends without an error reports nothing at all. Before this bound, such a request held its
    /// page forever. Every other page finished around it, so the row stood at N-1 of N with the
    /// active badge, and the image-transfer watchdog never ran because no transfer had started.
    ///
    /// Ten seconds above the request's own twenty-second interval, so an ordinary URLSession timeout
    /// still reports first and keeps its error.
    static let viewerStageDeadlineInterval: TimeInterval = 30
    /// The same bound for the recovery attempt, ten seconds above its thirty-second interval.
    static let viewerRetryStageDeadlineInterval: TimeInterval = 40

    static func viewerStageDeadline(retryingViewerConnection: Bool) -> TimeInterval {
        retryingViewerConnection ? viewerRetryStageDeadlineInterval : viewerStageDeadlineInterval
    }

    /// Runs `operation` and fails with the retryable `AppError.networkingFailed` if it has not
    /// finished `seconds` after it started, measured on `clock`.
    ///
    /// **It returns at the deadline whether or not the operation honours cancellation.** The
    /// operation is cancelled and left to unwind on its own, rather than awaited, because the stage
    /// this exists for is one whose load never answers, and nothing guarantees it answers its
    /// cancellation either. A late result after the deadline is discarded.
    ///
    /// Cancelling the caller cancels the operation and throws `CancellationError`, so a pause still
    /// reads as a pause rather than a failed page.
    nonisolated static func withPageStageDeadline<Value: Sendable>(
        seconds: TimeInterval,
        clock: any Clock<Duration>,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let race = PageStageRace<Value>()
        let work = Task {
            do {
                race.settle(.success(try await operation()))
            } catch {
                race.settle(.failure(error))
            }
        }
        let deadline = Task {
            do {
                try await clock.sleep(for: .seconds(seconds))
            } catch {
                return
            }
            race.settle(.failure(AppError.networkingFailed))
            work.cancel()
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.wait(continuation)
            }
        } onCancel: {
            race.settle(.failure(CancellationError()))
            work.cancel()
        }
    }
}

/// The first of the operation, the deadline and the caller's cancellation to report wins, once.
///
/// A report can arrive before the caller has begun waiting, because a cancellation handler runs
/// at once for an already-cancelled task, so a report with no waiter is held until one arrives.
private final class PageStageRace<Value: Sendable>: Sendable {
    private enum State {
        case idle
        case waiting(CheckedContinuation<Value, any Error>)
        case settled(Result<Value, any Error>)
        case finished
    }

    private let state = Mutex(State.idle)

    func wait(_ continuation: CheckedContinuation<Value, any Error>) {
        let result: Result<Value, any Error>? = state.withLock { state in
            guard case .settled(let result) = state else {
                state = .waiting(continuation)
                return nil
            }
            state = .finished
            return result
        }
        if let result {
            continuation.resume(with: result)
        }
    }

    func settle(_ result: Result<Value, any Error>) {
        let continuation: CheckedContinuation<Value, any Error>? = state.withLock { state in
            switch state {
            case .idle:
                state = .settled(result)
                return nil
            case .waiting(let continuation):
                state = .finished
                return continuation
            case .settled, .finished:
                return nil
            }
        }
        continuation?.resume(with: result)
    }
}
