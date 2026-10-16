import SwiftUI

/// 背景・透かし・接地影・作品を重ねたプレビュー。書き出し（Renderer）と同じ配置・同じ式で表示する。
/// 作品は縮小画像を表示しているだけで、書き出しは元の解像度で行う。
struct LiveCompositionPreview: View {
    let interactive: Bool
    let showsWatermark: Bool

    @Environment(EditSession.self) private var session
    @State private var background: CGImage?
    @State private var subject: SubjectPreview?

    private struct BackgroundKey: Equatable {
        let backgroundID: String?
        let adjustments: BackgroundAdjustments
        let ratio: AspectRatio
        let hasOriginal: Bool
    }

    var body: some View {
        Group {
            if let original = session.originalImage {
                let canvas = Canvas.size(imageWidth: original.width, imageHeight: original.height,
                                         ratio: session.composition.ratio)
                CompositionCanvas(
                    canvasSize: CGSize(width: canvas.width, height: canvas.height),
                    originalSize: CGSize(width: original.width, height: original.height),
                    background: background,
                    subject: subject,
                    composition: session.composition,
                    showsWatermark: showsWatermark,
                    onTransformChange: interactive ? { session.composition.transform = $0 } : nil
                )
            } else {
                Color.clear
            }
        }
        .task(id: BackgroundKey(backgroundID: session.composition.backgroundID,
                                adjustments: session.composition.adjustments,
                                ratio: session.composition.ratio,
                                hasOriginal: session.originalImage != nil)) {
            guard let original = session.originalImage else { return }
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            let composition = session.composition
            let library = BackgroundLibrary.shared
            let canvas = Canvas.size(imageWidth: original.width, imageHeight: original.height, ratio: composition.ratio)
            let rendered = await Task.detached(priority: .userInitiated) {
                Renderer.backgroundPreview(item: library.item(id: composition.backgroundID), library: library,
                                           canvasWidth: canvas.width, canvasHeight: canvas.height,
                                           adjustments: composition.adjustments, originalImage: original)
            }.value
            if !Task.isCancelled {
                background = rendered
            }
        }
        .task(id: session.maskVersion) {
            guard let original = session.originalImage, let mask = session.mask else { return }
            subject = await Task.detached(priority: .userInitiated) {
                SubjectPreview.make(original: original, mask: mask)
            }.value
        }
    }
}

struct CompositionCanvas: View {
    let canvasSize: CGSize
    let originalSize: CGSize
    let background: CGImage?
    let subject: SubjectPreview?
    let composition: Composition
    let showsWatermark: Bool
    /// nil なら操作できない（書き出し画面）。
    let onTransformChange: ((SubjectTransform) -> Void)?

    @GestureState private var dragTranslation: CGSize = .zero
    @GestureState private var magnification: CGFloat = 1
    @GestureState private var twist: Angle = .zero

    var body: some View {
        GeometryReader { geometry in
            let rect = ImageFit.rect(for: canvasSize, in: geometry.size)
            let k = rect.width / max(canvasSize.width, 1)
            let transform = liveTransform(scale: k)
            let shortSide = Double(min(canvasSize.width, canvasSize.height))
            let watermarkFont: CGFloat = max(14, CGFloat(shortSide) * 0.035) * k
            let shadowBlur: CGFloat = CGFloat(composition.shadow.blurPixels(canvasShortSide: shortSide)) * k
            let shadowOffset: CGFloat = CGFloat(composition.shadow.offsetPixels(canvasShortSide: shortSide)) * k
            let center = CGPoint(x: (canvasSize.width / 2 + transform.offset.width) * k,
                                 y: (canvasSize.height / 2 + transform.offset.height) * k)
            let subjectSize = CGSize(width: originalSize.width * k, height: originalSize.height * k)

            ZStack {
                if let background {
                    Image(decorative: background, scale: 1)
                        .resizable()
                        .frame(width: rect.width, height: rect.height)
                } else {
                    Color(white: 0.92)
                }

                if showsWatermark {
                    Text(Renderer.watermarkText)
                        .font(.system(size: watermarkFont, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .shadow(color: .black.opacity(0.45), radius: watermarkFont * 0.25)
                        .padding(CGFloat(shortSide) * 0.03 * k)
                        .frame(width: rect.width, height: rect.height, alignment: .bottomTrailing)
                }

                if let subject {
                    if composition.shadow.isEnabled {
                        Image(decorative: subject.shadow, scale: 1)
                            .resizable()
                            .frame(width: subjectSize.width, height: subjectSize.height)
                            .scaleEffect(CGFloat(transform.scale))
                            .rotationEffect(Angle(radians: transform.rotation))
                            .blur(radius: shadowBlur)
                            .opacity(composition.shadow.opacity)
                            .position(x: center.x, y: center.y + shadowOffset)
                    }
                    Image(decorative: subject.cutout, scale: 1)
                        .resizable()
                        .frame(width: subjectSize.width, height: subjectSize.height)
                        .scaleEffect(CGFloat(transform.scale))
                        .rotationEffect(Angle(radians: transform.rotation))
                        .position(center)
                } else {
                    ProgressView()
                }
            }
            .frame(width: rect.width, height: rect.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(gesture(scale: k), including: onTransformChange == nil ? .none : .all)
            .position(x: rect.midX, y: rect.midY)
        }
    }

    private func liveTransform(scale k: CGFloat) -> SubjectTransform {
        var transform = composition.transform
        transform.offset.width += dragTranslation.width / max(k, 0.0001)
        transform.offset.height += dragTranslation.height / max(k, 0.0001)
        transform.scale *= magnification
        transform.rotation += twist.radians
        return transform
    }

    private func gesture(scale k: CGFloat) -> some Gesture {
        SimultaneousGesture(SimultaneousGesture(DragGesture(minimumDistance: 1), MagnifyGesture()), RotateGesture())
            .updating($dragTranslation) { value, state, _ in
                state = value.first?.first?.translation ?? .zero
            }
            .updating($magnification) { value, state, _ in
                state = value.first?.second?.magnification ?? 1
            }
            .updating($twist) { value, state, _ in
                state = value.second?.rotation ?? .zero
            }
            .onEnded { value in
                var transform = composition.transform
                if let translation = value.first?.first?.translation {
                    transform.offset.width += translation.width / max(k, 0.0001)
                    transform.offset.height += translation.height / max(k, 0.0001)
                }
                if let magnification = value.first?.second?.magnification {
                    transform.scale *= magnification
                }
                if let rotation = value.second?.rotation {
                    transform.rotation += rotation.radians
                }
                onTransformChange?(transform.snapped())
            }
    }
}
