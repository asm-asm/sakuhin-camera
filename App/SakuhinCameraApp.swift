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

struct RootView: View {
    @State private var path: [Route] = []
    @State private var session = EditSession()

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
    }
}
