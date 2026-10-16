import CoreGraphics
import Foundation

/// 書き出しの縦横比。
enum AspectRatio: String, CaseIterable, Identifiable {
    case original
    case square
    case portrait4x5
    case story9x16

    var id: String { rawValue }

    var label: String {
        switch self {
        case .original: return "元の比率"
        case .square: return "1:1"
        case .portrait4x5: return "4:5"
        case .story9x16: return "9:16"
        }
    }

    /// 幅 ÷ 高さ。元の比率なら nil。
    var value: Double? {
        switch self {
        case .original: return nil
        case .square: return 1
        case .portrait4x5: return 4.0 / 5.0
        case .story9x16: return 9.0 / 16.0
        }
    }
}

/// 背景レイヤーだけにかける調整。作品には一切かけない。
struct BackgroundAdjustments: Equatable {
    /// 露出（EV）。-1〜1
    var brightness: Double = 0
    /// 色温度。-1（青み）〜1（暖かみ）
    var temperature: Double = 0
    /// ぼかし。0〜1
    var blur: Double = 0
}

/// 接地影。作品のマスクをずらしてぼかし、背景レイヤーに落とす。
struct ShadowSettings: Equatable {
    var isEnabled = true
    /// 濃さ。0〜1
    var opacity: Double = 0.35
    /// ぼかし量。0〜1
    var blur: Double = 0.4
    /// 下方向へのずれ量。0〜1
    var offset: Double = 0.25

    /// キャンバスの短辺に対する画素数。
    func offsetPixels(canvasShortSide: Double) -> Double { offset * 0.04 * canvasShortSide }
    func blurPixels(canvasShortSide: Double) -> Double { (0.004 + blur * 0.03) * canvasShortSide }
}

/// 作品の配置。位置はキャンバス中央からのずれ（元写真の画素単位）。
struct SubjectTransform: Equatable {
    var offset: CGSize = .zero
    var scale: Double = 1
    var rotation: Double = 0

    /// 拡大縮小・回転なし。このときは画素をそのまま写す（リサンプリングしない）。
    var isUnscaled: Bool { scale == 1 && rotation == 0 }

    /// 原寸・回転なしに近ければぴったりに寄せる（作品を無加工のまま置きやすくする）。
    func snapped() -> SubjectTransform {
        var result = self
        if abs(result.scale - 1) < 0.03 { result.scale = 1 }
        if abs(result.rotation) < 2 * Double.pi / 180 { result.rotation = 0 }
        result.scale = min(max(result.scale, 0.2), 4)
        return result
    }
}

struct Composition: Equatable {
    var backgroundID: String?
    var adjustments = BackgroundAdjustments()
    var shadow = ShadowSettings()
    var transform = SubjectTransform()
    var ratio: AspectRatio = .original
}

enum Canvas {
    /// 元写真がすべて収まる、指定比率の最小のキャンバス（元写真の画素単位）。
    static func size(imageWidth w: Int, imageHeight h: Int, ratio: AspectRatio) -> (width: Int, height: Int) {
        guard let r = ratio.value else { return (w, h) }
        let imageRatio = Double(w) / Double(h)
        if imageRatio > r {
            return (w, Int((Double(w) / r).rounded()))
        } else {
            return (Int((Double(h) * r).rounded()), h)
        }
    }
}
