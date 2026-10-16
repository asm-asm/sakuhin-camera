import CoreGraphics
import Foundation

/// 背景画面のプレビュー用に縮小した、切り抜き済みの作品画像と影の形。
/// 書き出しは Renderer が元の解像度で行う（このプレビューは表示専用）。
struct SubjectPreview {
    /// 作品（マスクを α にした画像）。
    let cutout: CGImage
    /// 影の形（黒・マスクを α にした画像）。
    let shadow: CGImage

    static func make(original: CGImage, mask: AlphaMask, maxDimension: Double = 1200) -> SubjectPreview? {
        let factor = min(1, maxDimension / Double(max(original.width, original.height)))
        let w = max(1, Int((Double(original.width) * factor).rounded()))
        let h = max(1, Int((Double(original.height) * factor).rounded()))
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        guard let maskImage = mask.makeCGImage() else { return nil }

        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drewPhoto = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.draw(original, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        var alpha = [UInt8](repeating: 0, count: w * h)
        let drewMask = alpha.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.draw(maskImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drewPhoto, drewMask else { return nil }

        var shadowPixels = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let a = UInt32(alpha[i])
            let base = i * 4
            pixels[base] = UInt8(UInt32(pixels[base]) * a / 255)
            pixels[base + 1] = UInt8(UInt32(pixels[base + 1]) * a / 255)
            pixels[base + 2] = UInt8(UInt32(pixels[base + 2]) * a / 255)
            pixels[base + 3] = alpha[i]
            shadowPixels[base + 3] = alpha[i]
        }
        guard let cutout = RGBAImage(width: w, height: h, colorSpace: space, pixels: pixels).makeCGImage(),
              let shadow = RGBAImage(width: w, height: h, colorSpace: space, pixels: shadowPixels).makeCGImage()
        else { return nil }
        return SubjectPreview(cutout: cutout, shadow: shadow)
    }
}
