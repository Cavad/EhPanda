import AnalyticsClient
public import AppModels
import AppTools
public import ComposableArchitecture
public import DateSeekFeature
public import FiltersFeature
import Foundation
import HapticsClient
public import NetworkingFeature
public import Sharing

@Reducer
public struct FrontPageReducer: Sendable {
    public enum Delegate: Equatable, Sendable {
        case pushDetail(Gallery)
    }

    @Reducer
    public enum Destination {
        case filters(FiltersReducer)
        case dateSeek(DateSeekReducer)
    }

    private enum CancelID {
        case fetchGalleries, fetchMoreGalleries, fetchDateSeekGalleries
    }

    @ObservableState
    public struct State: Equatable {
        @SharedReader(.globalFilter) public var globalFilter: Filter
        @SharedReader(.tagTranslator) public var tagTranslator: TagTranslator
        @SharedReader(.setting) public var setting: Setting
        @Presents public var destination: Destination.State?
        public var keyword = ""

        var filteredGalleries: [Gallery] {
            guard !keyword.isEmpty else { return galleries }
            return galleries.filter({ $0.titleMatches(keyword) })
        }
        public var galleries = [Gallery]()
        public var pageNumber = PageNumber()
        public var dateSeekNavigation: DateSeekNavigation?
        public var loadingState: LoadingState = .idle
        public var footerLoadingState: LoadingState = .idle

        public init() {}
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        case onPresented
        case delegate(Delegate)
        case filtersButtonTapped
        case dateSeekButtonTapped(DateSeekNavigation)
        case destination(PresentationAction<Destination.Action>)

        case fetchGalleries
        case fetchGalleriesDone(Result<GalleriesResult, AppError>)
        case fetchMoreGalleries
        case fetchMoreGalleriesDone(Result<GalleriesResult, AppError>)
        case performDateSeekDone(Result<GalleriesResult, AppError>)
    }

    @Dependency(\.analyticsClient) private var analyticsClient
    @Dependency(\.hapticsClient) private var hapticsClient

    public init() {}

    public var body: some Reducer<State, Action> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            // Presentation-driven lifecycle: the presenting reducer sends this as part of the
            // state transition that pushes this screen, replacing the former view `onAppear`.
            // The empty guard keeps it idempotent — re-presenting a populated list refetches nothing.
            case .onPresented:
                guard state.galleries.isEmpty else { return .none }
                return .send(.fetchGalleries)

            case .delegate:
                return .none

            case .filtersButtonTapped:
                state.destination = .filters(FiltersReducer.State())
                // Presenting the sheet loads the persisted filters into it, replacing the form's
                // former `onAppear`. Every screen that presents Filters must send this.
                // Records that the filter panel was opened here (D-14). Applying a filter mutates a
                // persisted shared value with no distinct reducer action, so only the open is counted.
                return .merge(
                    .send(.destination(.presented(.filters(.fetchFilters)))),
                    .run(operation: { _ in analyticsClient.send(.filterPanelOpened(.frontPage)) })
                )

            case .dateSeekButtonTapped(let navigation):
                state.destination = .dateSeek(.init(navigation: navigation))
                return .none

            case .fetchGalleries:
                guard state.loadingState != .loading else { return .none }
                state.loadingState = .loading
                state.footerLoadingState = .idle
                state.pageNumber.resetPages()
                let filter = state.globalFilter
                let host = state.setting.galleryHost
                let request = Effect<Action>.run { send in
                    let result = await Result.Swift::init { () async throws(AppError) in
                        try await FrontPageGalleriesRequest(host: host, filter: filter).response()
                    }
                    await send(.fetchGalleriesDone(result))
                }
                .cancellable(id: CancelID.fetchGalleries)
                return .merge(.cancel(id: CancelID.fetchMoreGalleries), request)

            case .fetchGalleriesDone(let result):
                state.loadingState = .idle
                switch result {
                case .success(let response):
                    let galleries = response.galleries
                    state.pageNumber = response.pageNumber
                    state.dateSeekNavigation = response.dateSeekNavigation
                    state.galleries = galleries
                    if galleries.isEmpty {
                        state.loadingState = .failed(.notFound)
                        if state.pageNumber.galleryCursor(lastID: nil) != nil {
                            return .send(.fetchMoreGalleries)
                        }
                    }
                    return .none
                case .failure(let error):
                    state.loadingState = .failed(error)
                }
                return .none

            case .fetchMoreGalleries:
                guard state.loadingState != .loading, state.footerLoadingState != .loading,
                      let lastID = state.pageNumber.galleryCursor(lastID: state.galleries.last?.id)
                else { return .none }
                state.footerLoadingState = .loading
                let filter = state.globalFilter
                let host = state.setting.galleryHost
                return .run { send in
                    let result = await Result.Swift::init { () async throws(AppError) in
                        try await MoreFrontPageGalleriesRequest(
                            host: host,
                            filter: filter,
                            lastID: lastID
                        )
                        .response()
                    }
                    await send(.fetchMoreGalleriesDone(result))
                }
                .cancellable(id: CancelID.fetchMoreGalleries)

            case .fetchMoreGalleriesDone(let result):
                guard state.footerLoadingState == .loading else { return .none }
                state.footerLoadingState = .idle
                switch result {
                case .success(let response):
                    let galleries = response.galleries
                    let previousCursor = state.pageNumber.galleryCursor(lastID: state.galleries.last?.id)
                    var nextPage = response.pageNumber
                    nextPage.stopIfCursorStalls(after: previousCursor, lastID: galleries.last?.id)
                    state.pageNumber = nextPage
                    state.dateSeekNavigation = response.dateSeekNavigation
                    let previousCount = state.galleries.count
                    state.galleries.appendUniqueGalleries(contentsOf: galleries)
                    if state.galleries.count > previousCount {
                        state.loadingState = .idle
                    } else if nextPage.galleryCursor(lastID: nil) != nil {
                        return .send(.fetchMoreGalleries)
                    }
                    return .none

                case .failure(let error):
                    state.footerLoadingState = .failed(error)
                }
                return .none

            case .destination(.presented(.dateSeek(.delegate(.performSeek(let url))))):
                guard state.loadingState != .loading else { return .none }
                state.loadingState = .loading
                state.footerLoadingState = .idle
                state.pageNumber.resetPages()
                let host = state.setting.galleryHost
                let request = Effect<Action>.run { send in
                    let result = await Result.Swift::init { () async throws(AppError) in
                        try await DateSeekGalleriesRequest(host: host, url: url).response()
                    }
                    await send(.performDateSeekDone(result))
                }
                .cancellable(id: CancelID.fetchDateSeekGalleries)
                return .merge(.cancel(id: CancelID.fetchMoreGalleries), request)

            case .performDateSeekDone(let result):
                state.loadingState = .idle
                switch result {
                case .success(let response):
                    let galleries = response.galleries
                    guard !galleries.isEmpty else {
                        state.loadingState = .failed(.notFound)
                        return .none
                    }
                    state.pageNumber = response.pageNumber
                    state.dateSeekNavigation = response.dateSeekNavigation
                    state.galleries = galleries
                    return .none
                case .failure(let error):
                    state.loadingState = .failed(error)
                }
                return .none

            case .destination:
                return .none
            }
        }
        .haptics(
            unwrapping: \.destination,
            case: \.filters,
            hapticsClient: hapticsClient
        )
        .haptics(
            unwrapping: \.destination,
            case: \.dateSeek,
            hapticsClient: hapticsClient
        )
        .ifLet(\.$destination, action: \.destination)
    }
}

extension FrontPageReducer.Destination.State: Equatable, Sendable {}
