import Photos
import SwiftUI
import UniformTypeIdentifiers

/// 書き出し画面。比率を選び、写真に保存・共有・説明文のコピー。
struct ExportScreen: View {
    let onFinish: () -> Void

    @Environment(EditSession.self) private var session
    @Environment(SubscriptionStore.self) private var store
    @State private var exported: ExportedImage?
    @State private var isRendering = false
    @State private var renderError: String?
    @State private var saveState: SaveState = .idle
    @State private var copied = false
    @State private var showsPaywall = false

    private enum SaveState: Equatable {
        case idle
        case saving
        case saved
        case failed(String)
    }

    private struct RenderKey: Equatable {
        let composition: Composition
        let maskVersion: Int
        let watermark: Bool
    }

    private let library = BackgroundLibrary.shared

    var body: some View {
        @Bindable var session = session
        VStack(spacing: 12) {
            Picker("比率", selection: $session.composition.ratio) {
                ForEach(AspectRatio.allCases) { ratio in
                    Text(ratio.label).tag(ratio)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            LiveCompositionPreview(interactive: false, showsWatermark: usesWatermark)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal)

            if usesWatermark {
                Button {
                    showsPaywall = true
                } label: {
                    Label("透かしを消す（プレミアム）", systemImage: "crown")
                        .font(.footnote)
                }
            }

            captionBox

            HStack(spacing: 12) {
                Button {
                    Task { await save() }
                } label: {
                    Label(saveLabel, systemImage: saveState == .saved ? "checkmark" : "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(exported == nil || saveState == .saving)

                if let exported {
                    ShareLink(item: exported.url) {
                        Label("共有", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {} label: {
                        Label("共有", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(true)
                }
            }
            .controlSize(.large)
            .padding(.horizontal)

            Group {
                if isRendering {
                    ProgressView("書き出し中…")
                } else if let renderError {
                    Text(renderError).foregroundStyle(.red)
                } else if case .failed(let message) = saveState {
                    Text(message).foregroundStyle(.red)
                } else {
                    Button("新しく撮る", action: onFinish)
                }
            }
            .font(.footnote)
            .frame(height: 28)
            .padding(.bottom, 8)
        }
        .navigationTitle("書き出し")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsPaywall) {
            PaywallView()
        }
        .task(id: RenderKey(composition: session.composition, maskVersion: session.maskVersion, watermark: usesWatermark)) {
            await render()
        }
    }

    private var usesWatermark: Bool { !store.isPremium }

    private var background: BackgroundItem? {
        let item = library.item(id: session.composition.backgroundID)
        // 有料背景はプレミアムのときだけ使う
        if let item, item.premium, !store.isPremium {
            return library.defaultItem
        }
        return item
    }

    private var caption: String {
        AppText.caption(aiGeneratedBackground: background?.aiGenerated ?? false)
    }

    private var captionBox: some View {
        HStack {
            Text(caption)
                .font(.footnote)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? "コピーしました" : "コピー") {
                UIPasteboard.general.string = caption
                copied = true
            }
            .font(.footnote)
            .buttonStyle(.bordered)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
        .padding(.horizontal)
    }

    private var saveLabel: String {
        switch saveState {
        case .saving: return "保存中…"
        case .saved: return "保存しました"
        default: return "写真に保存"
        }
    }

    private func render() async {
        guard let original = session.originalImage, let mask = session.mask else { return }
        exported = nil
        saveState = .idle
        renderError = nil
        isRendering = true
        defer { isRendering = false }

        let composition = session.composition
        let background = background
        let watermark = usesWatermark
        let library = library
        let result = await Task.detached(priority: .userInitiated) { () -> ExportedImage? in
            guard let pixels = try? RGBAImage(cgImage: original),
                  let output = try? Renderer.render(original: pixels, originalImage: original, mask: mask,
                                                    background: background, library: library,
                                                    composition: composition, watermark: watermark),
                  let image = output.image.makeCGImage(),
                  let data = ExportEncoder.jpegData(image)
            else { return nil }
            return ExportEncoder.write(data)
        }.value

        guard !Task.isCancelled else { return }
        if let result {
            exported = result
        } else {
            renderError = "書き出しに失敗しました"
        }
    }

    private func save() async {
        guard let exported else { return }
        saveState = .saving
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            saveState = .failed("写真への保存が許可されていません。設定アプリで「写真」を「追加のみ」以上にしてください。")
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: exported.data, options: nil)
            }
            saveState = .saved
        } catch {
            saveState = .failed("保存できませんでした（\(error.localizedDescription)）")
        }
    }
}

struct ExportedImage {
    let data: Data
    let url: URL
}

enum ExportEncoder {
    static func jpegData(_ image: CGImage, quality: Double = 0.95) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// 共有シート用に一時ファイルへ書き出す。
    static func write(_ data: Data) -> ExportedImage? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sakuhin_\(formatter.string(from: Date())).jpg")
        do {
            try data.write(to: url, options: .atomic)
            return ExportedImage(data: data, url: url)
        } catch {
            return nil
        }
    }
}
