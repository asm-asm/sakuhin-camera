import SwiftUI

/// 撮影画面。撮った写真は EditSession に入れ、プレビューで「撮り直し / 次へ」を選ぶ。
/// 写真ライブラリからの読み込みはしない（アプリ内カメラのみ）。
struct CameraScreen: View {
    let onNext: () -> Void

    @Environment(EditSession.self) private var session
    @State private var showsSettings = false

    var body: some View {
        Group {
            if let image = session.originalImage {
                CapturedPreview(image: image, onRetake: { session.reset() }, onNext: onNext)
            } else {
                LiveCameraView(onCaptured: { image in
                    session.reset()
                    session.originalImage = image
                })
            }
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("撮影")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.black, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("設定")
            }
        }
        .sheet(isPresented: $showsSettings) {
            SettingsView()
        }
    }
}

private struct LiveCameraView: View {
    let onCaptured: (CGImage) -> Void

    @State private var camera = CameraController()
    @State private var level = MotionLevel()
    @State private var focusPoint: CGPoint?
    @State private var errorMessage: String?
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                // 写真は縦 4:3。プレビューは切り取らずに表示するので、同じ枠にガイドを描く
                let photoFrame = ImageFit.rect(for: CGSize(width: 3, height: 4), in: geometry.size)
                ZStack {
                    content(photoFrame: photoFrame)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            shutterBar
        }
        .task {
            await camera.start()
            level.start()
        }
        .onDisappear {
            camera.stop()
            level.stop()
        }
        .task(id: focusPoint) {
            guard focusPoint != nil else { return }
            try? await Task.sleep(for: .seconds(1.2))
            focusPoint = nil
        }
        .alert("撮影できませんでした", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func content(photoFrame: CGRect) -> some View {
        switch camera.status {
        case .idle:
            ProgressView()
                .tint(.white)
        case .running:
            CameraPreviewView(camera: camera) { point in
                focusPoint = point
            }
            GuideOverlay(photoFrame: photoFrame, reading: level.reading)
                .allowsHitTesting(false)
            if let focusPoint {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(.yellow, lineWidth: 1.5)
                    .frame(width: 72, height: 72)
                    .position(focusPoint)
                    .allowsHitTesting(false)
            }
        case .unauthorized:
            message("カメラへのアクセスが許可されていません。設定アプリで「カメラ」をオンにしてください。") {
                Button("設定を開く") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        case .unavailable:
            message("この端末ではカメラを使えません。") {
                sampleButton
            }
        case .failed(let reason):
            message("カメラを起動できませんでした（\(reason)）") {
                EmptyView()
            }
        }
    }

    private var shutterBar: some View {
        ZStack {
            Button(action: shoot) {
                Circle()
                    .fill(.white)
                    .frame(width: 66, height: 66)
                    .overlay(Circle().stroke(.white, lineWidth: 3).padding(-7))
                    .opacity(camera.isCapturing ? 0.5 : 1)
            }
            .disabled(camera.status != .running || camera.isCapturing)
            .accessibilityLabel("撮影")

            HStack {
                Spacer()
                sampleButton
            }
            .padding(.horizontal)
        }
        .frame(height: 110)
        .frame(maxWidth: .infinity)
    }

    /// カメラのないシミュレータと開発用ビルドだけで出す、同梱サンプル写真での動作確認。
    @ViewBuilder
    private var sampleButton: some View {
        #if DEBUG || targetEnvironment(simulator)
        Button("サンプル") {
            if let image = SampleImage.load() {
                onCaptured(image)
            }
        }
        .buttonStyle(.bordered)
        .tint(.white)
        #endif
    }

    private func message<Actions: View>(_ text: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 20) {
            Text(text)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            actions()
        }
        .padding(32)
    }

    private func shoot() {
        Task {
            do {
                let image = try await camera.capture()
                camera.stop()
                onCaptured(image)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// 中央ガイド枠と水平ガイド。
private struct GuideOverlay: View {
    let photoFrame: CGRect
    let reading: LevelReading?

    var body: some View {
        let side = min(photoFrame.width, photoFrame.height) * 0.7
        ZStack {
            CornerBrackets()
                .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: side, height: side)
                .position(x: photoFrame.midX, y: photoFrame.midY)
            if let reading {
                LevelView(reading: reading)
                    .position(x: photoFrame.midX, y: photoFrame.midY)
            }
        }
    }
}

private struct CornerBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        let length = min(rect.width, rect.height) * 0.12
        var path = Path()
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: rect.minX, y: rect.minY), 1, 1),
            (CGPoint(x: rect.maxX, y: rect.minY), -1, 1),
            (CGPoint(x: rect.minX, y: rect.maxY), 1, -1),
            (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1),
        ]
        for (corner, dx, dy) in corners {
            path.move(to: CGPoint(x: corner.x + dx * length, y: corner.y))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * length))
        }
        return path
    }
}

/// 撮影直後の確認。
private struct CapturedPreview: View {
    let image: CGImage
    let onRetake: () -> Void
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 16) {
                Button("撮り直す", action: onRetake)
                    .buttonStyle(.bordered)
                    .tint(.white)
                Button("次へ", action: onNext)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .frame(height: 110)
        }
    }
}
