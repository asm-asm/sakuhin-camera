import CoreGraphics
import Observation

/// 撮影から書き出しまでの 1 枚分の編集状態。
@Observable
final class EditSession {
    /// 撮影した元写真（向きは .up に正規化済み）。作品の画素はここから一切変えない。
    var originalImage: CGImage?
    /// 被写体の選択から作ったマスク（ブラシ修正の前）。
    var baseMask: AlphaMask?
    /// 縁の調整を終えた最終マスク（元写真と同じ大きさ）。
    private(set) var mask: AlphaMask?
    /// mask が変わるたびに増える。プレビュー画像の作り直しに使う。
    private(set) var maskVersion = 0
    /// 背景・調整・影・配置・比率。背景の選択は撮り直しても引き継ぐ。
    var composition = Composition()

    func setMask(_ mask: AlphaMask?) {
        self.mask = mask
        maskVersion += 1
    }

    func reset() {
        originalImage = nil
        baseMask = nil
        setMask(nil)
        composition.transform = SubjectTransform()
    }
}

enum Route: Hashable {
    case cutout
    case refine
    case background
    case export
}
