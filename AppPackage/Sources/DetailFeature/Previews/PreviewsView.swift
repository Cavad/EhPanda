import AppComponents
import AppModels
import ComposableArchitecture
import ReadingFeature
import Resources
import SFSafeSymbols
import SwiftUI

struct PreviewsView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @Bindable private var store: StoreOf<PreviewsReducer>

    init(store: StoreOf<PreviewsReducer>) {
        self.store = store
    }

    private var gridItems: [GridItem] {
        [GridItem(
            .adaptive(
                minimum: DetailLayout.previewGridMinimumWidth(
                    regular: horizontalSizeClass == .regular
                ),
                maximum: DetailLayout.previewGridMaximumWidth(
                    regular: horizontalSizeClass == .regular
                )
            ),
            spacing: 10,
            alignment: .bottom
        )]
    }

    var body: some View {
        let localPreviewURLs = store.localPreviewURLs
        let remotePreviewURLs = store.previewURLs
        ScrollView {
            LazyVGrid(columns: gridItems) {
                ForEach(0..<max(store.gallery.pageCount, 0), id: \.self) { offset in
                    let page = offset + 1
                    VStack {
                        Button {
                            store.send(.updateReadingProgress(page))
                            store.send(.openReading(page))
                        } label: {
                            PreviewThumbnail(url: localPreviewURLs[page] ?? remotePreviewURLs[page])
                        }
                        // The thumbnail is the button's only content; the page it opens is its name.
                        .accessibilityLabel(.accessibilityPreviewPage(page: page))
                        Text(page, format: .number)
                            .font(horizontalSizeClass == .regular ? .callout : .caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal)
            .padding(.bottom)
        }
        .fullScreenCover(
            item: $store.scope(\.$destination, action: \.destination).reading
        ) { store in
            ReadingView(store: store)
                .privacyMask()
        }
        .onScrollTargetVisibilityChange(idType: Int.self) { visibleOffsets in
            store.send(.visiblePagesChanged(visibleOffsets.map({ $0 + 1 })))
        }
        .toolbar {
            if store.hasFailedVisiblePreviews {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        store.send(.retryVisiblePreviews)
                    } label: {
                        Label(.RLocalizable.retry, systemSymbol: .arrowClockwise)
                    }
                }
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .navigationTitle(.previews)
    }
}

#Preview("Loaded") {
    NavigationStack {
        PreviewsView(
            store: .init(initialState: .init(gallery: .preview), reducer: PreviewsReducer.init)
        )
    }
}
