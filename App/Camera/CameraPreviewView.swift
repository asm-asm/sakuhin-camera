import AVFoundation
import SwiftUI
import UIKit

/// カメラのライブ映像。写真と同じ範囲が見えるよう、切り取らずに全体を表示する。
struct CameraPreviewView: UIViewRepresentable {
    let camera: CameraController
    /// タップ位置（このビュー上の座標）。ピント・露出合わせはこのビューが行う。
    let onTap: (CGPoint) -> Void

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.videoGravity = .resizeAspect
        camera.attachPreview(view.previewLayer)
        update(view)
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        update(uiView)
    }

    private func update(_ view: PreviewUIView) {
        let camera = camera
        let onTap = onTap
        view.onTap = { layerPoint, devicePoint in
            camera.focus(at: devicePoint)
            onTap(layerPoint)
        }
    }
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    var onTap: ((CGPoint, CGPoint) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self)
        onTap?(point, previewLayer.captureDevicePointConverted(fromLayerPoint: point))
    }
}
