import Foundation

/// 最終合成。式は `出力 = 背景 × (1 − マスク) + 元写真 × マスク` のみ。
///
/// Core Image のフィルタは浮動小数・色管理を通るため丸め誤差で作品の画素が 1 ずれることがある。
/// そこで最終合成だけは整数演算で行い、マスク=255 の画素が元写真と完全一致することを保証する。
/// 背景側の調整（明るさ・色温度・ぼかし・影）は、この関数に渡す前の背景レイヤーにだけ適用すること。
enum Compositor {
    enum Error: Swift.Error, Equatable {
        case sizeMismatch
    }

    static func composite(original: RGBAImage, mask: AlphaMask, background: RGBAImage) throws -> RGBAImage {
        guard original.width == mask.width, original.height == mask.height,
              original.width == background.width, original.height == background.height
        else { throw Error.sizeMismatch }

        let pixelCount = original.width * original.height
        var output = [UInt8](repeating: 0, count: pixelCount * 4)

        original.pixels.withUnsafeBufferPointer { (src: UnsafeBufferPointer<UInt8>) in
            background.pixels.withUnsafeBufferPointer { (bg: UnsafeBufferPointer<UInt8>) in
                mask.values.withUnsafeBufferPointer { (m: UnsafeBufferPointer<UInt8>) in
                    output.withUnsafeMutableBufferPointer { (dst: inout UnsafeMutableBufferPointer<UInt8>) in
                        for i in 0..<pixelCount {
                            let alpha = UInt32(m[i])
                            let base = i * 4
                            for c in base..<(base + 4) {
                                dst[c] = blend(background: bg[c], original: src[c], alpha: alpha)
                            }
                        }
                    }
                }
            }
        }

        return RGBAImage(width: original.width, height: original.height,
                         colorSpace: original.colorSpace, pixels: output)
    }

    /// alpha=255 のとき (original×255 + 127) / 255 = original で必ず元の値になる。
    @inline(__always)
    private static func blend(background: UInt8, original: UInt8, alpha: UInt32) -> UInt8 {
        let bgPart: UInt32 = UInt32(background) * (255 - alpha)
        let originalPart: UInt32 = UInt32(original) * alpha
        return UInt8((bgPart + originalPart + 127) / 255)
    }
}
