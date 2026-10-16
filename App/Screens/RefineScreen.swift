import SwiftUI
import UIKit

@MainActor
@Observable
final class RefineModel {
    enum Brush: String, CaseIterable, Identifiable {
        case add
        case erase

        var id: String { rawValue }
        var label: String { self == .add ? "追加" : "消去" }
    }

    static let displayMaxDimension = 1400

    private(set) var mask: AlphaMask
    private(set) var displayMask: AlphaMask
    private(set) var overlay: CGImage?
    private(set) var canUndo = false
    private(set) var isFinishing = false
    var brush: Brush = .add
    /// 画面上のブラシの直径（ポイント）。
    var brushDiameter: Double = 36
    var softness: EdgeSoftness = .medium

    @ObservationIgnored private let initialMask: AlphaMask
    @ObservationIgnored private var strokes: [MaskStroke] = []
    @ObservationIgnored private var currentStroke = MaskStroke()

    init(mask: AlphaMask) {
        self.mask = mask
        initialMask = mask
        displayMask = mask.downscaled(maxDimension: Self.displayMaxDimension)
        overlay = Self.makeOverlay(displayMask)
    }

    func beginStroke() {
        currentStroke = MaskStroke()
    }

    func paint(from start: CGPoint, to end: CGPoint, radius: Double) {
        mask.paint(from: start, to: end, radius: radius, add: brush == .add, recordingInto: &currentStroke)
        // 表示用マスクも同じ位置を塗る（縮小率に合わせる）
        let factor = Double(displayMask.width) / Double(mask.width)
        var ignored = MaskStroke()
        displayMask.paint(from: CGPoint(x: start.x * factor, y: start.y * factor),
                          to: CGPoint(x: end.x * factor, y: end.y * factor),
                          radius: radius * factor, add: brush == .add, recordingInto: &ignored)
        overlay = Self.makeOverlay(displayMask)
    }

    func endStroke() {
        guard !currentStroke.indices.isEmpty else { return }
        strokes.append(currentStroke)
        currentStroke = MaskStroke()
        canUndo = true
    }

    func undo() {
        guard let last = strokes.popLast() else { return }
        mask.undo(last)
        refreshDisplay()
        canUndo = !strokes.isEmpty
    }

    func resetToAutomatic() {
        mask = initialMask
        strokes.removeAll()
        canUndo = false
        refreshDisplay()
    }

    /// 縁をなめらかにした最終マスクを作る。
    func finish(original: CGImage) async -> AlphaMask? {
        isFinishing = true
        defer { isFinishing = false }
        let mask = mask
        let softness = softness
        return await Task.detached(priority: .userInitiated) {
            guard softness != .none, let guide = try? RGBAImage(cgImage: original),
                  guide.width == mask.width, guide.height == mask.height
            else { return mask }
            let radius = softness.radius(forLongSide: max(mask.width, mask.height))
            return EdgeRefiner.feather(mask: mask, guide: guide, radius: radius)
        }.value
    }

    private func refreshDisplay() {
        displayMask = mask.downscaled(maxDimension: Self.displayMaxDimension)
        overlay = Self.makeOverlay(displayMask)
    }

    /// 作品＝透明、背景＝赤紫の半透明で塗った重ね画像。
    static func makeOverlay(_ mask: AlphaMask) -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: mask.width * mask.height * 4)
        for i in 0..<(mask.width * mask.height) {
            let alpha = Double(255 - Int(mask.values[i])) * 0.5 / 255
            pixels[i * 4] = UInt8(230 * alpha)
            pixels[i * 4 + 1] = UInt8(30 * alpha)
            pixels[i * 4 + 2] = UInt8(110 * alpha)
            pixels[i * 4 + 3] = UInt8(255 * alpha)
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        return RGBAImage(width: mask.width, height: mask.height, colorSpace: space, pixels: pixels).makeCGImage()
    }
}

/// 縁の調整画面。1本指で塗る、2本指で拡大・移動。
struct RefineScreen: View {
    let onNext: () -> Void

    @Environment(EditSession.self) private var session
    @State private var model: RefineModel?

    var body: some View {
        Group {
            if let model, let image = session.originalImage {
                content(model: model, image: image)
            } else {
                ContentUnavailableView("マスクがありません", systemImage: "scissors")
            }
        }
        .navigationTitle("縁の調整")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if model == nil, let baseMask = session.baseMask {
                model = RefineModel(mask: baseMask)
            }
        }
    }

    private func content(model: RefineModel, image: CGImage) -> some View {
        @Bindable var model = model
        return VStack(spacing: 12) {
            RefineCanvas(image: image, model: model)
                .background(Color.black)

            VStack(spacing: 10) {
                HStack {
                    Picker("ブラシ", selection: $model.brush) {
                        ForEach(RefineModel.Brush.allCases) { brush in
                            Text(brush.label).tag(brush)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 180)

                    Spacer()

                    Button {
                        model.undo()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .disabled(!model.canUndo)
                    .accessibilityLabel("1つ戻す")

                    Button("自動に戻す") {
                        model.resetToAutomatic()
                    }
                    .font(.footnote)
                }

                HStack {
                    Image(systemName: "circle.fill").font(.system(size: 6))
                    Slider(value: $model.brushDiameter, in: 8...120)
                    Image(systemName: "circle.fill").font(.system(size: 18))
                }

                HStack {
                    Text("縁のなめらかさ")
                        .font(.footnote)
                    Picker("縁のなめらかさ", selection: $model.softness) {
                        ForEach(EdgeSoftness.allCases) { softness in
                            Text(softness.label).tag(softness)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Text("1本指でなぞって塗る・2本指で拡大と移動。毛羽のある作品は「なめらかさ」を強めにすると自然になります")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    Task {
                        if let final = await model.finish(original: image) {
                            session.setMask(final)
                            onNext()
                        }
                    }
                } label: {
                    if model.isFinishing {
                        ProgressView()
                    } else {
                        Text("次へ")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isFinishing)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }
}

/// UIScrollView で拡大縮小し、1本指のなぞりでマスクを塗るキャンバス。
private struct RefineCanvas: UIViewRepresentable {
    let image: CGImage
    let model: RefineModel

    func makeUIView(context: Context) -> RefineCanvasView {
        let view = RefineCanvasView(image: image)
        view.model = model
        view.overlayView.image = model.overlay.map { UIImage(cgImage: $0) }
        return view
    }

    func updateUIView(_ view: RefineCanvasView, context: Context) {
        view.model = model
        view.brushDiameter = model.brushDiameter
        view.overlayView.image = model.overlay.map { UIImage(cgImage: $0) }
    }
}

final class RefineCanvasView: UIView, UIScrollViewDelegate {
    let scrollView = UIScrollView()
    let contentView = UIView()
    let photoView = UIImageView()
    let overlayView = UIImageView()
    private let cursor = CAShapeLayer()
    private let imagePixelSize: CGSize
    weak var model: RefineModel?
    var brushDiameter: Double = 36
    private var lastPoint: CGPoint?

    init(image: CGImage) {
        imagePixelSize = CGSize(width: image.width, height: image.height)
        super.init(frame: .zero)
        backgroundColor = .black

        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 10
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.panGestureRecognizer.minimumNumberOfTouches = 2
        scrollView.contentInsetAdjustmentBehavior = .never
        addSubview(scrollView)

        photoView.image = UIImage(cgImage: image)
        photoView.contentMode = .scaleToFill
        overlayView.contentMode = .scaleToFill
        overlayView.layer.magnificationFilter = .nearest
        contentView.addSubview(photoView)
        contentView.addSubview(overlayView)
        scrollView.addSubview(contentView)

        cursor.fillColor = UIColor.clear.cgColor
        cursor.strokeColor = UIColor.white.cgColor
        cursor.lineWidth = 1.5
        cursor.isHidden = true
        layer.addSublayer(cursor)

        let paint = UIPanGestureRecognizer(target: self, action: #selector(handlePaint(_:)))
        paint.maximumNumberOfTouches = 1
        contentView.addGestureRecognizer(paint)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        scrollView.frame = bounds
        let fitted = ImageFit.rect(for: imagePixelSize, in: bounds.size)
        if contentView.bounds.size != fitted.size {
            scrollView.zoomScale = 1
            contentView.frame = CGRect(origin: .zero, size: fitted.size)
            photoView.frame = contentView.bounds
            overlayView.frame = contentView.bounds
            scrollView.contentSize = fitted.size
        }
        centerContent()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        contentView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
    }

    private func centerContent() {
        let size = contentView.frame.size
        let insetX = max(0, (scrollView.bounds.width - size.width) / 2)
        let insetY = max(0, (scrollView.bounds.height - size.height) / 2)
        scrollView.contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
    }

    @objc private func handlePaint(_ recognizer: UIPanGestureRecognizer) {
        guard let model else { return }
        let location = recognizer.location(in: contentView)
        let pixelsPerPoint = imagePixelSize.width / max(contentView.bounds.width, 1)
        let point = CGPoint(x: location.x * pixelsPerPoint, y: location.y * pixelsPerPoint)
        // 画面上の直径をそのままに、拡大中は細かく塗れるようにする
        let radius = brushDiameter / 2 / Double(scrollView.zoomScale) * Double(pixelsPerPoint)

        switch recognizer.state {
        case .began:
            model.beginStroke()
            model.paint(from: point, to: point, radius: radius)
            lastPoint = point
        case .changed:
            model.paint(from: lastPoint ?? point, to: point, radius: radius)
            lastPoint = point
        default:
            model.endStroke()
            lastPoint = nil
        }
        overlayView.image = model.overlay.map { UIImage(cgImage: $0) }
        updateCursor(recognizer.location(in: self), visible: recognizer.state == .began || recognizer.state == .changed)
    }

    private func updateCursor(_ center: CGPoint, visible: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let d = brushDiameter
        cursor.path = UIBezierPath(ovalIn: CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)).cgPath
        cursor.isHidden = !visible
        CATransaction.commit()
    }
}
