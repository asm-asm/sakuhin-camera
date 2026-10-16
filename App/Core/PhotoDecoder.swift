import CoreGraphics
import Foundation
import ImageIO

/// 撮影データ（HEIF/JPEG）を、向きを正規化した（.up の）CGImage にする。
/// 向きの補正は画素の並べ替えだけで行い、色や値は一切変えない。
enum PhotoDecoder {
    enum Error: Swift.Error {
        case unreadable
    }

    static func uprightImage(from data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw Error.unreadable }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let rawOrientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: rawOrientation) ?? .up
        if orientation == .up {
            return image
        }
        guard let upright = try RGBAImage(cgImage: image).oriented(orientation).makeCGImage() else {
            throw Error.unreadable
        }
        return upright
    }
}

extension RGBAImage {
    /// EXIF の向き情報に従って画素を並べ替え、正しい向き（.up）の画像にする。
    func oriented(_ orientation: CGImagePropertyOrientation) -> RGBAImage {
        if orientation == .up { return self }
        let swapsAxes: Bool
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored: swapsAxes = true
        default: swapsAxes = false
        }
        let outWidth = swapsAxes ? height : width
        let outHeight = swapsAxes ? width : height
        let w = width
        let h = height

        var output = [UInt8](repeating: 0, count: pixels.count)
        pixels.withUnsafeBufferPointer { (src: UnsafeBufferPointer<UInt8>) in
            output.withUnsafeMutableBufferPointer { (dst: inout UnsafeMutableBufferPointer<UInt8>) in
                for y in 0..<outHeight {
                    for x in 0..<outWidth {
                        let s = Self.sourcePoint(x: x, y: y, width: w, height: h, orientation: orientation)
                        let si = (s.y * w + s.x) * 4
                        let di = (y * outWidth + x) * 4
                        dst[di] = src[si]
                        dst[di + 1] = src[si + 1]
                        dst[di + 2] = src[si + 2]
                        dst[di + 3] = src[si + 3]
                    }
                }
            }
        }
        return RGBAImage(width: outWidth, height: outHeight, colorSpace: colorSpace, pixels: output)
    }

    /// 表示座標 (x, y) に置く画素が、保存データ（幅 w・高さ h）のどこにあるか。
    private static func sourcePoint(x: Int, y: Int, width w: Int, height h: Int,
                                    orientation: CGImagePropertyOrientation) -> (x: Int, y: Int) {
        switch orientation {
        case .up: return (x, y)
        case .upMirrored: return (w - 1 - x, y)
        case .down: return (w - 1 - x, h - 1 - y)
        case .downMirrored: return (x, h - 1 - y)
        case .leftMirrored: return (y, x)
        case .right: return (y, h - 1 - x)
        case .rightMirrored: return (w - 1 - y, h - 1 - x)
        case .left: return (w - 1 - y, x)
        @unknown default: return (x, y)
        }
    }
}
