public import AppModels
import AppTools
public import ComposableArchitecture
import DownloadClient
public import Foundation
import HapticsClient
import NetworkingFeature
public import ReadingFeature
import Sharing

@Reducer
public struct PreviewsReducer: Sendable {
    @Reducer
    public enum Destination {
        case reading(ReadingReducer)
    }

    private enum CancelID {
        case observeDownloads
        case loadLocalPreviewURLs
        case fetchPreviewURLs
    }

    @ObservableState
    public struct State: Equatable, Sendable {
        @SharedReader(.setting) public var setting: Setting
        @Presents public var destination: Destination.State?

        // The gallery id this screen fetches; captured when pushed onto the host's gallery stack.
        public var gid: String
        public var gallery: Gallery
        // Threaded from the detail context (via the `pushPreviews` delegate) so a reader opened from
        // this screen keeps the correct page math (`previewConfig`) and Live Text `language` for
        // remote sessions — Previews itself never fetches a gallery detail to re-derive them.
        public var language: Language?
        var visiblePages = [Int]()
        var didLoadLocalPreviewURLs = false
        var loadingPreviewBatch: Int?
        var failedPreviewBatches = Set<Int>()

        public var previewURLs = [Int: URL]()
        public var localPreviewURLs = [Int: URL]()
        public var previewConfig: PreviewConfig = .normal(rows: 4)
        public var localPreviewRequestID = UUID()

        public init(
            gallery: Gallery,
            previewConfig: PreviewConfig = .normal(rows: 4), language: Language? = nil,
            previewURLs: [Int: URL] = [:]
        ) {
            self.gid = gallery.id
            self.gallery = gallery
            self.previewConfig = previewConfig
            self.language = language
            self.previewURLs = previewURLs
        }

        var hasFailedVisiblePreviews: Bool {
            visiblePages.contains(where: { page in
                guard let batch = missingPreviewBatch(for: page) else { return false }
                return failedPreviewBatches.contains(batch)
            })
        }

        var nextVisiblePreviewBatch: Int? {
            for page in visiblePages {
                guard let batch = missingPreviewBatch(for: page),
                      !failedPreviewBatches.contains(batch)
                else { continue }
                return batch
            }
            return nil
        }

        private func missingPreviewBatch(for page: Int) -> Int? {
            guard page > 0, page <= gallery.pageCount,
                  localPreviewURLs[page] == nil, previewURLs[page] == nil
            else { return nil }
            return previewConfig.pageNumber(index: page)
        }

        mutating func updatePreviewURLs(_ previewURLs: [Int: URL]) {
            self.previewURLs.merge(previewURLs, uniquingKeysWith: { _, fresh in fresh })
        }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        case destination(PresentationAction<Destination.Action>)

        case updateReadingProgress(Int)

        case onPresented
        case observeDownloads(String)
        case observeDownloadsDone([DownloadedGallery])
        case loadLocalPreviewURLs(String)
        case loadLocalPreviewURLsDone(requestID: UUID, urls: [Int: URL])
        case openReading(Int)
        case openReadingDone(Result<(download: DownloadedGallery, manifest: DownloadManifest), AppError>)
        case visiblePagesChanged([Int])
        case retryVisiblePreviews
        case fetchPreviewURLsDone(batch: Int, result: Result<[Int: URL], AppError>)
    }

    @Dependency(\.downloadClient) private var downloadClient
    @Dependency(\.hapticsClient) private var hapticsClient
    @Dependency(\.date) private var date

    public init() {}

    public var body: some Reducer<State, Action> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .destination(.presented(.reading(.onPerformDismiss))):
                return .send(.destination(.dismiss))

            case .destination:
                return .none

            case .updateReadingProgress(let progress):
                @Shared(.galleryHistory) var galleryHistory
                $galleryHistory.withLock {
                    $0.updateReadingProgress(
                        gid: state.gallery.id, token: state.gallery.token, progress: progress, date: date.now
                    )
                }
                return .none

            // Presentation-driven lifecycle: the host sends this in the state transition that pushes
            // this screen, replacing the former view `onAppear`. The gallery is seeded from the
            // pushing context; the remaining preview URLs are fetched as the grid is scrolled.
            case .onPresented:
                if state.visiblePages.isEmpty {
                    state.visiblePages = [1]
                }
                return .merge(
                    .send(.observeDownloads(state.gid)),
                    .send(.loadLocalPreviewURLs(state.gid))
                )

            case .observeDownloads(let gid):
                guard gid.isValidGID else { return .none }
                return .run { send in
                    var previousRelevantDownloads = [DownloadedGallery]()
                    var hadRelevantDownloads = false
                    for await downloads in downloadClient.observeDownloads() {
                        let relevantDownloads = downloads.filter({ $0.gid == gid })
                        let hasRelevantDownloads = !relevantDownloads.isEmpty
                        guard hasRelevantDownloads || hadRelevantDownloads else { continue }
                        if relevantDownloads == previousRelevantDownloads {
                            hadRelevantDownloads = hasRelevantDownloads
                            continue
                        }
                        previousRelevantDownloads = relevantDownloads
                        hadRelevantDownloads = hasRelevantDownloads
                        await send(.observeDownloadsDone(relevantDownloads))
                    }
                }
                .cancellable(id: CancelID.observeDownloads, cancelInFlight: true)

            case .observeDownloadsDone:
                return .send(.loadLocalPreviewURLs(state.gallery.id))

            case .loadLocalPreviewURLs(let gid):
                guard gid.isValidGID else {
                    state.localPreviewRequestID = UUID()
                    state.localPreviewURLs = .init()
                    state.didLoadLocalPreviewURLs = true
                    return loadVisiblePreviews(state: &state)
                }
                let requestID = UUID()
                state.localPreviewRequestID = requestID
                return .run { send in
                    let localPreviewURLs = await downloadClient.loadLocalPageURLs(gid) ?? [:]
                    await send(.loadLocalPreviewURLsDone(requestID: requestID, urls: localPreviewURLs))
                }
                .cancellable(id: CancelID.loadLocalPreviewURLs, cancelInFlight: true)

            case .loadLocalPreviewURLsDone(let requestID, let localPreviewURLs):
                guard state.localPreviewRequestID == requestID else { return .none }
                state.didLoadLocalPreviewURLs = true
                if state.localPreviewURLs != localPreviewURLs {
                    state.localPreviewURLs = localPreviewURLs
                }
                return loadVisiblePreviews(state: &state)

            case .openReading:
                return .run { [galleryID = state.gallery.id] send in
                    guard galleryID.isValidGID else {
                        await send(.openReadingDone(.failure(.notFound)))
                        return
                    }
                    await send(.openReadingDone(.success(try await downloadClient.loadManifest(galleryID))))
                } catch: { error, send in
                    await send(.openReadingDone(.failure(AppError(error))))
                }

            case .openReadingDone(let result):
                var readingState: ReadingReducer.State
                if case .success(let (download, manifest)) = result {
                    readingState = .init(
                        gallery: state.gallery, contentSource: .local(download: download, manifest: manifest),
                        previewConfig: state.previewConfig, language: state.language
                    )
                } else {
                    readingState = .init(
                        gallery: state.gallery, contentSource: .remote,
                        previewConfig: state.previewConfig, language: state.language
                    )
                    readingState.localPageURLs = state.localPreviewURLs
                }
                state.destination = .reading(readingState)
                return .send(.destination(.presented(.reading(.onPresented))))

            case .visiblePagesChanged(let pages):
                state.visiblePages = pages
                return loadVisiblePreviews(state: &state)

            case .retryVisiblePreviews:
                state.failedPreviewBatches.removeAll()
                return loadVisiblePreviews(state: &state)

            case .fetchPreviewURLsDone(let batch, let result):
                guard state.loadingPreviewBatch == batch else { return .none }
                state.loadingPreviewBatch = nil
                if case .success(let urls) = result {
                    state.updatePreviewURLs(urls)
                    // A partial response can fill some tiles. Retry the batch only on demand if
                    // there are still holes, including a response with no usable preview URLs.
                    let firstPage = batch * state.previewConfig.batchSize + 1
                    let batchRange = state.previewConfig.batchRange(index: firstPage)
                    if batchRange.prefix(while: { $0 <= state.gallery.pageCount }).contains(where: {
                        state.previewURLs[$0] == nil && state.localPreviewURLs[$0] == nil
                    }) {
                        state.failedPreviewBatches.insert(batch)
                    }
                } else {
                    state.failedPreviewBatches.insert(batch)
                }
                return loadVisiblePreviews(state: &state)
            }
        }
        .haptics(
            unwrapping: \.destination,
            case: \.reading,
            hapticsClient: hapticsClient
        )
        .ifLet(\.$destination, action: \.destination)
    }

    private func loadVisiblePreviews(state: inout State) -> Effect<Action> {
        guard state.didLoadLocalPreviewURLs, state.loadingPreviewBatch == nil,
              let galleryURL = state.gallery.galleryURL
        else { return .none }

        // Keep one request in flight. When it finishes, choose from the current viewport so a
        // fast scroll doesn't leave a backlog of batches for tiles the reader has already passed.
        guard let batch = state.nextVisiblePreviewBatch else { return .none }

        state.loadingPreviewBatch = batch
        return .run { send in
            let result = await Result.Swift::init { () async throws(AppError) in
                try await GalleryPreviewURLsRequest(galleryURL: galleryURL, pageNum: batch).response()
            }
            await send(.fetchPreviewURLsDone(batch: batch, result: result))
        }
        .cancellable(id: CancelID.fetchPreviewURLs)
    }
}

extension PreviewsReducer.Destination.State: Equatable, Sendable {}
