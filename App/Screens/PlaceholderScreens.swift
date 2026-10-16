import SwiftUI

// 画面遷移の骨組み。各画面は実装の段階ごとに別ファイルへ置き換える。

struct BackgroundScreen: View {
    let onNext: () -> Void

    @Environment(EditSession.self) private var session
    @State private var preview: CGImage?

    var body: some View {
        VStack(spacing: 16) {
            Group {
                if let preview {
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text("背景画面（段階5で実装）。今は単色背景との合成を表示しています")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("次へ", action: onNext)
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .navigationTitle("背景")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard preview == nil, let image = session.originalImage, let mask = session.mask else { return }
            preview = await Task.detached(priority: .userInitiated) {
                Self.compositeOnPlainBackground(image: image, mask: mask)
            }.value
        }
    }

    private static func compositeOnPlainBackground(image: CGImage, mask: AlphaMask) -> CGImage? {
        guard let original = try? RGBAImage(cgImage: image) else { return nil }
        let color: [UInt8] = [236, 240, 244, 255]
        var pixels = [UInt8](repeating: 0, count: original.pixels.count)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = color[0]
            pixels[i + 1] = color[1]
            pixels[i + 2] = color[2]
            pixels[i + 3] = color[3]
        }
        let background = RGBAImage(width: original.width, height: original.height,
                                   colorSpace: original.colorSpace, pixels: pixels)
        return try? Compositor.composite(original: original, mask: mask, background: background).makeCGImage()
    }
}

struct ExportScreen: View {
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text("書き出し画面（段階7で実装）")
                .foregroundStyle(.secondary)
            Button("最初に戻る", action: onFinish)
                .buttonStyle(.borderedProminent)
        }
        .navigationTitle("書き出し")
        .navigationBarTitleDisplayMode(.inline)
    }
}
