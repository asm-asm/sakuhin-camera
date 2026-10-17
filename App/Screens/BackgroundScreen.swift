import ImageIO
import SwiftUI

/// 背景画面。背景の選択・背景だけの調整・接地影・作品の配置。
struct BackgroundScreen: View {
    let onNext: () -> Void

    private enum Panel: String, CaseIterable, Identifiable {
        case background = "背景"
        case adjust = "調整"
        case shadow = "影"
        var id: String { rawValue }
    }

    @Environment(EditSession.self) private var session
    @Environment(SubscriptionStore.self) private var store
    @State private var panel: Panel = .background
    /// 選んでいるカテゴリ。nil なら「すべて」。
    @State private var category: String?
    @State private var showsPaywall = false

    private let library = BackgroundLibrary.shared

    var body: some View {
        @Bindable var session = session
        VStack(spacing: 10) {
            Picker("比率", selection: $session.composition.ratio) {
                ForEach(AspectRatio.allCases) { ratio in
                    Text(ratio.label).tag(ratio)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            LiveCompositionPreview(interactive: true, showsWatermark: !store.isPremium)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal)

            transformStatus

            Picker("編集", selection: $panel) {
                ForEach(Panel.allCases) { panel in
                    Text(panel.rawValue).tag(panel)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            Group {
                switch panel {
                case .background: backgroundPanel
                case .adjust: adjustPanel
                case .shadow: shadowPanel
                }
            }
            .frame(height: 214)

            Button("次へ", action: onNext)
                .buttonStyle(.borderedProminent)
                .disabled(session.mask == nil)
                .padding(.bottom, 8)
        }
        .navigationTitle("背景")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsPaywall) {
            PaywallView()
        }
        .onAppear {
            if library.item(id: session.composition.backgroundID) == nil {
                session.composition.backgroundID = library.defaultItem?.id
            }
        }
    }

    private var transformStatus: some View {
        HStack(spacing: 12) {
            if session.composition.transform.isUnscaled {
                Label("作品は原寸のまま（無加工）", systemImage: "checkmark.seal")
                    .foregroundStyle(.green)
            } else {
                Label("作品を拡大縮小・回転中（画素の補間のみ）", systemImage: "arrow.up.left.and.arrow.down.right")
                    .foregroundStyle(.secondary)
            }
            if session.composition.transform != SubjectTransform() {
                Button("位置を戻す") {
                    session.composition.transform = SubjectTransform()
                }
            }
        }
        .font(.caption)
    }

    // MARK: - 背景の一覧

    private var backgroundPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button("すべて") {
                        category = nil
                    }
                    .buttonStyle(.bordered)
                    .tint(category == nil ? .accentColor : .gray)
                    .controlSize(.small)

                    ForEach(library.categories, id: \.self) { name in
                        Button(BackgroundLibrary.displayName(ofCategory: name)) {
                            category = name
                        }
                        .buttonStyle(.bordered)
                        .tint(category == name ? .accentColor : .gray)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                // 2段に並べて、たくさんの背景を少ないスクロールで見られるようにする
                LazyHGrid(rows: [GridItem(.fixed(84), spacing: 6), GridItem(.fixed(84))], spacing: 8) {
                    ForEach(category.map(library.items(in:)) ?? library.items) { item in
                        BackgroundTile(item: item,
                                       isSelected: session.composition.backgroundID == item.id,
                                       isLocked: item.premium && !store.isPremium) {
                            if item.premium && !store.isPremium {
                                showsPaywall = true
                            } else {
                                session.composition.backgroundID = item.id
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    // MARK: - 背景の調整

    private var adjustPanel: some View {
        @Bindable var session = session
        return VStack(spacing: 6) {
            LabeledSlider(title: "明るさ", value: $session.composition.adjustments.brightness, range: -1...1)
            LabeledSlider(title: "色温度", value: $session.composition.adjustments.temperature, range: -1...1)
            LabeledSlider(title: "ぼかし", value: $session.composition.adjustments.blur, range: 0...1)
            HStack {
                Text("調整は背景だけにかかります。作品は変わりません")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("リセット") {
                    session.composition.adjustments = BackgroundAdjustments()
                }
                .font(.caption)
            }
        }
        .padding(.horizontal)
    }

    // MARK: - 接地影

    private var shadowPanel: some View {
        @Bindable var session = session
        return VStack(spacing: 6) {
            Toggle("接地影", isOn: $session.composition.shadow.isEnabled)
            LabeledSlider(title: "濃さ", value: $session.composition.shadow.opacity, range: 0...1)
                .disabled(!session.composition.shadow.isEnabled)
            LabeledSlider(title: "ぼかし", value: $session.composition.shadow.blur, range: 0...1)
                .disabled(!session.composition.shadow.isEnabled)
            LabeledSlider(title: "ずれ", value: $session.composition.shadow.offset, range: 0...1)
                .disabled(!session.composition.shadow.isEnabled)
        }
        .padding(.horizontal)
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack {
            Text(title)
                .font(.footnote)
                .frame(width: 56, alignment: .leading)
            Slider(value: $value, in: range)
        }
    }
}

private struct BackgroundTile: View {
    let item: BackgroundItem
    let isSelected: Bool
    let isLocked: Bool
    let onTap: () -> Void

    @Environment(EditSession.self) private var session
    @State private var thumbnail: CGImage?

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let thumbnail {
                            Image(decorative: thumbnail, scale: 1)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Color(white: 0.9)
                        }
                    }
                    .frame(width: 52, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.accentColor : Color.black.opacity(0.1), lineWidth: isSelected ? 3 : 1)
                    )
                    if isLocked {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .padding(4)
                            .background(Circle().fill(.black.opacity(0.55)))
                            .foregroundStyle(.white)
                            .padding(4)
                    }
                }
                Text(item.name)
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(width: 58)
            }
        }
        .buttonStyle(.plain)
        .task(id: item.id) {
            let original = session.originalImage
            let library = BackgroundLibrary.shared
            thumbnail = await Task.detached(priority: .utility) {
                BackgroundThumbnail.make(item: item, library: library, original: original)
            }.value
        }
    }
}

/// 背景一覧・購入画面で使うサムネイル。
enum BackgroundThumbnail {
    static func make(item: BackgroundItem, library: BackgroundLibrary, original: CGImage?,
                     maxPixelSize: Int = 240) -> CGImage? {
        if let url = library.fileURL(for: item) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        return Renderer.backgroundPreview(item: item, library: library, canvasWidth: 132, canvasHeight: 176,
                                          adjustments: BackgroundAdjustments(), originalImage: original)
    }
}

