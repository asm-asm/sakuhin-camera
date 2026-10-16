import CoreGraphics

/// 画像を枠に収めて（アスペクトフィット）表示するときの座標計算。
enum ImageFit {
    static func rect(for imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (container.width - size.width) / 2,
                      y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// 枠内のタップ位置を画像上の正規化座標（0〜1）にする。画像の外なら nil。
    static func normalizedPoint(_ point: CGPoint, imageSize: CGSize, in container: CGSize) -> CGPoint? {
        let frame = rect(for: imageSize, in: container)
        guard frame.width > 0, frame.height > 0, frame.contains(point) else { return nil }
        return CGPoint(x: (point.x - frame.minX) / frame.width,
                       y: (point.y - frame.minY) / frame.height)
    }
}
