import AppModels
import ComposableArchitecture
@testable import DetailFeature
import Foundation
import Testing

@Suite
struct GalleryNavigationTests {
    // A minimal gallery whose `id` ("1") drives the detail route key that dedup compares.
    private let galleryOne = Gallery(
        gid: "1", token: "", title: "", rating: 0, tags: [],
        category: .doujinshi, uploader: "", pageCount: 1,
        postedDate: .distantPast, coverURL: nil, galleryURL: nil
    )

    @Test
    func openingPreviewsReusesRemoteURLsAndTheConfiguredBatchSize() throws {
        let url = try #require(URL(string: "https://example.com/preview.jpg"))
        var gallery = galleryOne
        gallery.pageCount = 90
        let screen = GalleryNavigation.nextScreen(for: .detail(.delegate(.pushPreviews(
            gallery: gallery, previewConfig: .large(rows: 8), language: nil, previewURLs: [1: url]
        ))))
        guard case .previews(var state) = screen else {
            Issue.record("Expected a gallery preview screen.")
            return
        }
        state.visiblePages = [1]
        #expect(state.previewURLs == [1: url])
        #expect(state.nextVisiblePreviewBatch == nil)

        // A visible page in the middle of a batch can start that batch.
        state.visiblePages = [43, 44, 87]
        #expect(state.nextVisiblePreviewBatch == 1)

        state.failedPreviewBatches = [1]
        #expect(state.hasFailedVisiblePreviews)
        #expect(state.nextVisiblePreviewBatch == 2)

        state.visiblePages = [44]
        state.localPreviewURLs[44] = URL(filePath: "/tmp/preview-44.jpg")
        #expect(!state.hasFailedVisiblePreviews)
        #expect(state.nextVisiblePreviewBatch == nil)
    }

    // appendGuardingDuplicate skips only an adjacent identical element, so a rapid double-activation
    // pushes one screen while a legitimate same-gid re-push through a deeper screen still appends.
    @Test
    func appendGuardingDuplicateSkipsOnlyAdjacentDuplicates() {
        var path = StackState<GalleryPath.State>()

        path.appendGuardingDuplicate(.detail(.init(gallery: galleryOne)))
        #expect(path.count == 1)

        // A second identical push (double-tap) is skipped.
        path.appendGuardingDuplicate(.detail(.init(gallery: galleryOne)))
        #expect(path.count == 1)

        // A different screen is appended.
        path.appendGuardingDuplicate(.comments(.init(galleryURL: .mock)))
        #expect(path.count == 2)

        // The same detail after a non-adjacent screen is appended (only the top is compared).
        path.appendGuardingDuplicate(.detail(.init(gallery: galleryOne)))
        #expect(path.count == 3)
    }
}
