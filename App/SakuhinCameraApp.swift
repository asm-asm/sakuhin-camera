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
    /// プレミアム画面をプランの位置までスクロールする。
    static let paywallScrollToPlans = ProcessInfo.processInfo.arguments.contains("-paywallScrollToPlans")
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
        .onAppear(perform: startDemoSceneIfNeeded)
        .sheet(isPresented: $showsPaywallOnLaunch) {
            PaywallView()
        }
    }

    /// スクリーンショット撮影モード：本物の写真とマスクを入れて、指定の画面まで進める。
    private func startDemoSceneIfNeeded() {
        guard let scene = DemoContent.scene, let demo = DemoContent.shared, session.originalImage == nil else { return }
        session.originalImage = demo.photo
        session.baseMask = demo.mask
        session.setMask(demo.mask)
        if let backgroundID = DemoContent.backgroundID {
            session.composition.backgroundID = backgroundID
        }
        switch scene {
        case .preview: path = []
        case .cutout: path = [.cutout]
        case .background: path = [.cutout, .refine, .background]
        case .export: path = [.cutout, .refine, .background, .export]
        }
    }
}
