import AnalyticsClient
import AppModels
import AppTools
public import ComposableArchitecture
import DownloadClient
import Foundation
import LibraryClient
import OSLogExt
import Sharing
import SwiftUI
public import UIKit

private let logger = Logger(category: .init(describing: AppDelegateReducer.self))

@Reducer
struct AppDelegateReducer {
    @ObservableState
    struct State: Equatable {}

    enum Action: Equatable {
        case onLaunchFinish
    }

    @Dependency(\.libraryClient) private var libraryClient

    var body: some Reducer<State, Action> {
        Reduce { _, action in
            switch action {
            case .onLaunchFinish:
                return .merge(
                    // Enforce the browsing-history cap once per launch (in-session upserts never trim).
                    // Runs off the launch path as a background effect — decoding + re-encoding up to
                    // 1,000 entries shouldn't block `didFinishLaunching`; nothing reads history at start.
                    .run { _ in
                        @Shared(.galleryHistory) var galleryHistory
                        $galleryHistory.withLock({ $0.pruneToHistoryCap() })
                    },
                    // The analytics SDK no longer starts here; it waits behind `AppReducer`'s first-launch gate.
                    .run(operation: { _ in libraryClient.initializeWebImage() })
                )
            }
        }
    }
}

// MARK: AppDelegate
public class AppDelegate: UIResponder, UIApplicationDelegate {
    let store: StoreOf<AppReducer>

    public override init() {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        let configuration = UITestAutomation.prepare(environment: environment)
        let diagnosesDownloads = environment["EHPANDA_DOWNLOAD_DIAGNOSIS"] == "1"
        if diagnosesDownloads {
            UITestAutomation.applyFirstLaunchPreset(.answered)
            @Shared(.setting) var setting
            if environment["EHPANDA_AUTOMATION_GALLERY_URL"]?.hasPrefix("https://exhentai.org/") == true {
                $setting.withLock({ $0.galleryHost = .exhentai })
            }
        }
        #endif
        store = Store(initialState: .init(), reducer: AppReducer.init) { dependencies in
            #if DEBUG
            if diagnosesDownloads {
                dependencies.analyticsClient = .noop
            }
            if let configuration, configuration.shouldUseVisualTestHost {
                UITestAutomation.configureVisualTestHost(
                    &dependencies, firstLaunch: configuration.firstLaunchPreset
                )
            }
            #endif
        }
        super.init()
    }

    public func application(
        _ application: UIApplication, didFinishLaunchingWithOptions
            launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if !AppInfo.isTesting {
            store.send(.appDelegate(.onLaunchFinish))
        }
        return true
    }

    public func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        DownloadBackgroundSessionEvents.setCompletionHandler(
            completionHandler,
            for: identifier
        )
    }
}
