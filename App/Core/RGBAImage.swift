import CoreGraphics
import Foundation

/// 8bit RGBA の画素バッファ（写真は不透明なので α=255 前提）。
/// 元写真の色空間（iPhone なら Display P3）をそのまま保持し、色変換で作品の画素が変わらないようにする。
struct RGBAImage {
    let width: Int
    let height: Int
    let colorSpace: CGColorSpace
    /// width * height * 4 バイト。行の詰め物なし。
    var pixels: [UInt8]

    enum Error: Swift.Error {
        case contextCreationFailed
    }

    init(width: Int, height: Int, colorSpace: CGColorSpace, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 4)
        self.width = width
        self.height = height
        self.colorSpace = colorSpace
        self.pixels = pixels
    }

    /// CGImage を画素バッファにする。
    /// `colorSpace` を省略すると画像自身の色空間のまま読み込む（作品写真はこちらを使う）。
    /// 背景素材は合成先（元写真）の色空間を渡して変換しておく。
    init(cgImage: CGImage, colorSpace: CGColorSpace? = nil) throws {
        let space = colorSpace ?? Self.rgbColorSpace(of: cgImage)
        let w = cgImage.width
        let h = cgImage.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw Error.contextCreationFailed }
        self.init(width: w, height: h, colorSpace: space, pixels: pixels)
    }

    func makeCGImage() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private static func rgbColorSpace(of image: CGImage) -> CGColorSpace {
        if let space = image.colorSpace, space.model == .rgb {
            return space
        }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }
}

/// 被写体マスク。255 = 作品（元写真をそのまま使う）、0 = 背景。
struct AlphaMask {
    let width: Int
    let height: Int
    /// width * height バイト。
    var values: [UInt8]

    init(width: Int, height: Int, values: [UInt8]) {
        precondition(values.count == width * height)
        self.width = width
        self.height = height
        self.values = values
    }
}
