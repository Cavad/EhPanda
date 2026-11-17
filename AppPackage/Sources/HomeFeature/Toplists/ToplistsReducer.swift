public import AppComponents
public import AppModels
import AppTools
public import ComposableArchitecture
import HapticsClient
import NetworkingFeature
import Resources
import UIKit

@Reducer
public struct ToplistsReducer: Sendable {
    public enum Delegate: Equatable, Sendable {
        case pushDetail(Gallery)
    }

    public enum Alert: Equatable, Sendable {
        case performJumpPage
    }

    private enum CancelID {
        case fetchGalleries
        case fetchMoreGalleries(ToplistsType)
    }

    @ObservableState
    public struct State: Equatable {
        @SharedReader(.tagTranslator) public var tagTranslator: TagTranslator
        @SharedReader(.setting) public var setting: Setting
        public var keyword = ""
        public var jumpPageIndex = ""
        @Presents public var alert: AppAlertState<Alert>?

        public var type: ToplistsType = .yesterday

        var filteredGalleries: [Gallery]? {
            guard !keyword.isEmpty else { return galleries }
            return galleries?.filter({ $0.titleMatches(keyword) })
        }

        public var rawGalleries = [ToplistsType: [Gallery]]()
        public var rawPageNumber = [ToplistsType: PageNumber]()
        public var rawLoadingState = [ToplistsType: LoadingState]()
        public var rawFooterLoadingState = [ToplistsType: LoadingState]()

        var galleries: [Gallery]? {
            rawGalleries[type]
        }
        var pageNumber: PageNumber? {
            rawPageNumber[type]
        }
        var loadingState: LoadingState? {
            rawLoadingState[type]
        }
        var footerLoadingState: LoadingState? {
            rawFooterLoadingState[type]
        }

        public init() {}
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        case onPresented
        case delegate(Delegate)
        case setToplistsType(ToplistsType)

        case alert(PresentationAction<Alert>)
        case presentJumpPageAlert

        case fetchGalleries(pageNum: Int? = nil)
        case fetchGalleriesDone(
            type: ToplistsType, result: Result<(pageNumber: PageNumber, galleries: [Gallery]), AppError>
        )
        case fetchMoreGalleries
        case fetchMoreGalleriesDone(
            type: ToplistsType, result: Result<(pageNumber: PageNumber, galleries: [Gallery]), AppError>
        )
    }

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
                guard state.galleries?.isEmpty != false else { return .none }
                return .send(.fetchGalleries())

            case .delegate:
                return .none

            case .setToplistsType(let type):
                guard type != state.type else { return .none }
                state.type = type
                guard state.galleries?.isEmpty != false else { return .none }
                return .send(.fetchGalleries())

            case .alert(.presented(.performJumpPage)):
                guard let index = Int(state.jumpPageIndex),
                      let pageNumber = state.pageNumber,
                      index > 0, index <= pageNumber.maximum + 1 else {
                    return .run(operation: { _ in await hapticsClient.generateNotificationFeedback(.error) })
                }
                return .send(.fetchGalleries(pageNum: index - 1))

            case .alert:
                return .none

            case .presentJumpPageAlert:
                let maximumPage = (state.pageNumber?.maximum ?? 0) + 1
                state.alert = AppAlertState(
                    title: {
                        TextState(localized: .RLocalizable.jumpPage)
                    },
                    textField: .init(
                        placeholder: TextState(localized: .pageNumber),
                        keyboard: .numberPad
                    ),
                    actions: {
                        ButtonState(action: .performJumpPage) {
                            TextState(localized: .go)
                        }
                        ButtonState(role: .cancel) {
                            TextState(localized: .RLocalizable.cancel)
                        }
                    },
                    message: {
                        TextState(localized: .jumpPageDescription(max: maximumPage))
                    }
                )
                return .run(operation: { _ in await hapticsClient.generateFeedback(.light) })

            case .fetchGalleries(let pageNum):
                guard state.loadingState != .loading else { return .none }
                state.rawLoadingState[state.type] = .loading
                state.rawFooterLoadingState[state.type] = .idle
                if state.pageNumber == nil {
                    state.rawPageNumber[state.type] = PageNumber()
                } else {
                    state.rawPageNumber[state.type]?.resetPages()
                }
                let host = state.setting.galleryHost
                let request = Effect<Action>.run { [type = state.type] send in
                    let result = await Result.Swift::init { () async throws(AppError) in
                        try await ToplistsGalleriesRequest(
                            host: host,
                            catIndex: type.categoryIndex,
                            pageNum: pageNum
                        )
                        .response()
                    }
                    await send(.fetchGalleriesDone(type: type, result: result))
                }
                .cancellable(id: CancelID.fetchGalleries)
                return .merge(.cancel(id: CancelID.fetchMoreGalleries(state.type)), request)

            case .fetchGalleriesDone(let type, let result):
                state.rawLoadingState[type] = .idle
                switch result {
                case .success(let (pageNumber, galleries)):
                    state.rawPageNumber[type] = pageNumber
                    state.rawGalleries[type] = galleries
                    if galleries.isEmpty {
                        state.rawLoadingState[type] = .failed(.notFound)
                        if type == state.type, pageNumber.hasNextPage() {
                            return .send(.fetchMoreGalleries)
                        }
                    }
                    return .none
                case .failure(let error):
                    state.rawLoadingState[type] = .failed(error)
                }
                return .none

            case .fetchMoreGalleries:
                let pageNumber = state.pageNumber ?? .init()
                guard pageNumber.hasNextPage(), state.loadingState != .loading,
                      state.footerLoadingState != .loading
                else { return .none }
                state.rawFooterLoadingState[state.type] = .loading
                let pageNum = pageNumber.current + 1
                let host = state.setting.galleryHost
                return .run { [type = state.type] send in
                    let result = await Result.Swift::init { () async throws(AppError) in
                        try await MoreToplistsGalleriesRequest(
                            host: host,
                            catIndex: type.categoryIndex,
                            pageNum: pageNum
                        )
                        .response()
                    }
                    await send(.fetchMoreGalleriesDone(type: type, result: result))
                }
                .cancellable(id: CancelID.fetchMoreGalleries(state.type))

            case .fetchMoreGalleriesDone(let type, let result):
                guard state.rawFooterLoadingState[type] == .loading else { return .none }
                state.rawFooterLoadingState[type] = .idle
                switch result {
                case .success(let (pageNumber, galleries)):
                    let previousPage = state.rawPageNumber[type]?.current ?? 0
                    var nextPage = pageNumber
                    if nextPage.current <= previousPage {
                        nextPage = .init(current: previousPage, maximum: previousPage)
                    }
                    state.rawPageNumber[type] = nextPage
                    let previousCount = state.rawGalleries[type]?.count ?? 0
                    state.rawGalleries[type, default: []].appendUniqueGalleries(contentsOf: galleries)
                    if (state.rawGalleries[type]?.count ?? 0) > previousCount {
                        state.rawLoadingState[type] = .idle
                    } else if type == state.type, nextPage.hasNextPage() {
                        return .send(.fetchMoreGalleries)
                    }
                    return .none

                case .failure(let error):
                    state.rawFooterLoadingState[type] = .failed(error)
                }
                return .none
            }
        }
        .ifLet(\.$alert, action: \.alert)
    }
}
