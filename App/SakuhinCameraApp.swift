import SwiftUI

@main
struct SakuhinCameraApp: App {
    @State private var store = SubscriptionStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .task {
                    await store.start()
                }
        }
    }
}

/// 起動引数。CI のシミュレータで画面のスクリーンショットを撮るときに使う。
enum LaunchOptions {
    /// 起動直後にプレミアム画面を開く。
    static let showsPaywall = ProcessInfo.processInfo.arguments.contains("-showPaywall")
    /// ストアに接続せず、見本の料金でプランを表示する。
    static let paywallDemo = ProcessInfo.processInfo.arguments.contains("-paywallDemo")
}

struct RootView: View {
    @State private var path: [Route] = []
    @State private var session = EditSession()
    @State private var showsPaywallOnLaunch = LaunchOptions.showsPaywall

    var body: some View {
        NavigationStack(path: $path) {
            CameraScreen(onNext: { path.append(.cutout) })
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .cutout:
                        CutoutScreen(onNext: { path.append(.refine) })
                    case .refine:
                        RefineScreen(onNext: { path.append(.background) })
                    case .background:
                        BackgroundScreen(onNext: { path.append(.export) })
                    case .export:
                        ExportScreen(onFinish: {
                            session.reset()
                            path.removeAll()
                        })
                    }
                }
        }
        .environment(session)
        .sheet(isPresented: $showsPaywallOnLaunch) {
            PaywallView()
        }
    }
}
