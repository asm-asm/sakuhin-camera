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

        original.pixels.withUnsafeBufferPointer { src in
            background.pixels.withUnsafeBufferPointer { bg in
                mask.values.withUnsafeBufferPointer { m in
                    output.withUnsafeMutableBufferPointer { dst in
                        for i in 0..<pixelCount {
                            let a = UInt32(m[i])
                            let inv = 255 - a
                            let base = i * 4
                            for c in base..<(base + 4) {
                                // a=255 のとき (src×255 + 127) / 255 = src で必ず元の値になる
                                dst[c] = UInt8((UInt32(bg[c]) * inv + UInt32(src[c]) * a + 127) / 255)
                            }
                        }
                    }
                }
            }
        }

        return RGBAImage(width: original.width, height: original.height,
                         colorSpace: original.colorSpace, pixels: output)
    }
}
