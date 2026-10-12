import CoreGraphics
import Observation

/// 撮影から書き出しまでの 1 枚分の編集状態。
@Observable
final class EditSession {
    /// 撮影した元写真。作品の画素はここから一切変えない。
    var originalImage: CGImage?
    /// 切り抜きマスク（元写真と同じ大きさ）。
    var mask: AlphaMask?

    func reset() {
        originalImage = nil
        mask = nil
    }
}

enum Route: Hashable {
    case cutout
    case background
    case export
}
