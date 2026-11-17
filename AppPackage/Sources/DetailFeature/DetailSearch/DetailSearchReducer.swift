import AnalyticsClient
public import AppModels
import AppTools
public import ComposableArchitecture
public import FiltersFeature
import HapticsClient
import NetworkingFeature
public import QuickSearchFeature
public import Sharing

@Reducer
public struct DetailSearchReducer: Sendable {
    @Reducer
    public enum Destination {
        case filters(FiltersReducer)
        case quickSearch(QuickSearchReducer)
    }

    public enum Delegate: Equatable, Sendable {
        case pushDetail(Gallery)
    }

    private enum CancelID {
        case fetchGalleries, fetchMoreGalleries
    }

    @ObservableState
    public struct State: Equatable {
        @SharedReader(.searchFilter) public var searchFilter: Filter
        @SharedReader(.tagTranslator) public var tagTranslator: TagTranslator
        @SharedReader(.setting) public var setting: Setting
        @Presents public var destination: Destination.State?
        public var keyword = ""
        public var lastKeyword = ""

        public var galleries = [Gallery]()
        public var pageNumber = PageNumber()
        public var loadingState: LoadingState = .idle
        public var footerLoadingState: LoadingState = .idle

        public init(keyword: String = "") {
            self.keyword = keyword
            self.lastKeyword = keyword
        }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        case delegate(Delegate)
        case filtersButtonTapped
        case quickSearchButtonTapped
        case destination(PresentationAction<Destination.Action>)

        case onPresented
        case fetchGalleries(String? = nil)
        case fetchGalleriesDone(Result<(pageNumber: PageNumber, galleries: [Gallery]), AppError>)
        case fetchMoreGalleries
        case fetchMoreGalleriesDone(Result<(pageNumber: PageNumber, galleries: [Gallery]), AppError>)
    }

    @Dependency(\.analyticsClient) private var analyticsClient
    @Dependency(\.hapticsClient) private var hapticsClient

    public init() {}

    public var body: some Reducer<State, Action> {
        BindingReducer()
            .onChange(of: \.keyword) { _, state in
                if !state.keyword.isEmpty {
                    state.lastKeyword = state.keyword
                }
                return .none
            }

        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .delegate:
                return .none

            case .filtersButtonTapped:
                state.destination = .filters(FiltersReducer.State())
                // Presenting the sheet loads the persisted filters into it, replacing the form's
                // former `onAppear`. Every screen that presents Filters must send this.
                return .merge(
                    .run(operation: { _ in analyticsClient.send(.filterPanelOpened(.detailSearch)) }),
                    .send(.destination(.presented(.filters(.fetchFilters))))
                )

            case .quickSearchButtonTapped:
                state.destination = .quickSearch(QuickSearchReducer.State())
                return .run(operation: { _ in analyticsClient.send(.quickSearchPanelOpened(.detailSearch)) })

            case .destination:
                return .none

            // Presentation-driven lifecycle: the host sends this in the state transition that pushes
            // this screen, replacing the former view `onAppear`. The empty guard keeps it idempotent.
            case .onPresented:
                guard state.galleries.isEmpty else { return .none }
                return .send(.fetchGalleries(state.keyword))

            case .fetchGalleries(let keyword):
                guard state.loadingState != .loading else { return .none }
                if let keyword = keyword {
                    state.keyword = keyword
                    state.lastKeyword = keyword
                }
                state.loadingState = .loading
                state.footerLoadingState = .idle
                state.pageNumber.resetPages()
                let filter = state.searchFilter
                let host = state.setting.galleryHost
                let request = Effect<Action>.run { [lastKeyword = state.lastKeyword] send in
                    do throws(AppError) {
                        let response = try await SearchGalleriesRequest(
                            host: host,
                            keyword: lastKeyword,
                            filter: filter
                        )
                        .response()
                        await send(
                            .fetchGalleriesDone(.success((response.pageNumber, response.galleries)))
                        )
                    } catch {
                        await send(.fetchGalleriesDone(.failure(error)))
                    }
                }
                .cancellable(id: CancelID.fetchGalleries)
                return .merge(.cancel(id: CancelID.fetchMoreGalleries), request)

            case .fetchGalleriesDone(let result):
                state.loadingState = .idle
                switch result {
                case .success(let (pageNumber, galleries)):
                    state.pageNumber = pageNumber
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
                let filter = state.searchFilter
                let host = state.setting.galleryHost
                return .run { [lastKeyword = state.lastKeyword] send in
                    do throws(AppError) {
                        let response = try await MoreSearchGalleriesRequest(
                            host: host,
                            keyword: lastKeyword,
                            filter: filter,
                            lastID: lastID
                        )
                        .response()
                        await send(
                            .fetchMoreGalleriesDone(
                                .success((response.pageNumber, response.galleries))
                            )
                        )
                    } catch {
                        await send(.fetchMoreGalleriesDone(.failure(error)))
                    }
                }
                .cancellable(id: CancelID.fetchMoreGalleries)

            case .fetchMoreGalleriesDone(let result):
                guard state.footerLoadingState == .loading else { return .none }
                state.footerLoadingState = .idle
                switch result {
                case .success(let (pageNumber, galleries)):
                    let previousCursor = state.pageNumber.galleryCursor(lastID: state.galleries.last?.id)
                    var nextPage = pageNumber
                    nextPage.stopIfCursorStalls(after: previousCursor, lastID: galleries.last?.id)
                    state.pageNumber = nextPage
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
            }
        }
        .haptics(
            unwrapping: \.destination,
            case: \.quickSearch,
            hapticsClient: hapticsClient
        )
        .haptics(
            unwrapping: \.destination,
            case: \.filters,
            hapticsClient: hapticsClient
        )
        .ifLet(\.$destination, action: \.destination)
    }
}

extension DetailSearchReducer.Destination.State: Equatable, Sendable {}
