import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import UIKit

/// 最終画像の生成。
///
/// 1. 作品（元写真＋マスク）をキャンバスに配置する。原寸・回転なしなら画素をそのまま写す
/// 2. 背景レイヤーを作る：背景素材 → ぼかし・明るさ・色温度 → 接地影 → 透かし
/// 3. `Compositor` で `背景 × (1 − マスク) + 元写真 × マスク` を合成する
///
/// 調整・影・透かしはすべて背景レイヤーで行い、作品の画素には触れない。
enum Renderer {
    static let ciContext = CIContext(options: [.cacheIntermediates: false])

    struct Output {
        let image: RGBAImage
        let canvasMask: AlphaMask
    }

    static func render(original: RGBAImage, originalImage: CGImage, mask: AlphaMask,
                       background: BackgroundItem?, library: BackgroundLibrary,
                       composition: Composition, watermark: Bool) throws -> Output {
        let canvas = Canvas.size(imageWidth: original.width, imageHeight: original.height, ratio: composition.ratio)
        let placed = try placeSubject(original: original, originalImage: originalImage, mask: mask,
                                      canvasWidth: canvas.width, canvasHeight: canvas.height,
                                      transform: composition.transform)

        let canvasSize = CGSize(width: canvas.width, height: canvas.height)
        var backgroundImage = backgroundCIImage(item: background, library: library, canvasSize: canvasSize,
                                                adjustments: composition.adjustments, originalImage: originalImage)
        if composition.shadow.isEnabled, composition.shadow.opacity > 0 {
            backgroundImage = applyShadow(to: backgroundImage, mask: placed.mask, shadow: composition.shadow)
        }
        var backgroundLayer = try renderToPixels(backgroundImage, width: canvas.width, height: canvas.height,
                                                 colorSpace: original.colorSpace)
        if watermark {
            drawWatermark(on: &backgroundLayer)
        }

        let output = try Compositor.composite(original: placed.subject, mask: placed.mask, background: backgroundLayer)
        return Output(image: output, canvasMask: placed.mask)
    }

    // MARK: - 作品の配置

    static func placeSubject(original: RGBAImage, originalImage: CGImage?, mask: AlphaMask,
                             canvasWidth cw: Int, canvasHeight ch: Int,
                             transform: SubjectTransform) throws -> (subject: RGBAImage, mask: AlphaMask) {
        let centerX = Double(cw) / 2 + transform.offset.width
        let centerY = Double(ch) / 2 + transform.offset.height

        if transform.isUnscaled {
            // 整数画素だけずらしてそのまま写す。作品の画素は元写真と完全に一致する
            let tx = Int((centerX - Double(original.width) / 2).rounded())
            let ty = Int((centerY - Double(original.height) / 2).rounded())
            return copyPlacing(original: original, mask: mask, canvasWidth: cw, canvasHeight: ch, tx: tx, ty: ty)
        }

        let source = originalImage ?? original.makeCGImage()
        guard let source, let maskImage = mask.makeCGImage() else { throw RendererError.drawingFailed }
        let w = CGFloat(original.width)
        let h = CGFloat(original.height)
        let apply: (CGContext) -> Void = { context in
            context.interpolationQuality = .high
            // 左上原点・下向き y の座標にする
            context.translateBy(x: 0, y: CGFloat(ch))
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: centerX, y: centerY)
            context.rotate(by: transform.rotation)
            context.scaleBy(x: transform.scale, y: transform.scale)
            context.translateBy(x: -w / 2, y: -h / 2)
            // 画像は正しい向きで描く
            context.translateBy(x: 0, y: h)
            context.scaleBy(x: 1, y: -1)
        }

        var subjectPixels = [UInt8](repeating: 0, count: cw * ch * 4)
        let subjectDrawn = subjectPixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: cw, height: ch, bitsPerComponent: 8,
                                          bytesPerRow: cw * 4, space: original.colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            apply(context)
            context.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }

        var maskValues = [UInt8](repeating: 0, count: cw * ch)
        let maskDrawn = maskValues.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: cw, height: ch, bitsPerComponent: 8,
                                          bytesPerRow: cw, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            apply(context)
            context.draw(maskImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard subjectDrawn, maskDrawn else { throw RendererError.drawingFailed }

        return (RGBAImage(width: cw, height: ch, colorSpace: original.colorSpace, pixels: subjectPixels),
                AlphaMask(width: cw, height: ch, values: maskValues))
    }

    private static func copyPlacing(original: RGBAImage, mask: AlphaMask, canvasWidth cw: Int, canvasHeight ch: Int,
                                    tx: Int, ty: Int) -> (subject: RGBAImage, mask: AlphaMask) {
        var subjectPixels = [UInt8](repeating: 0, count: cw * ch * 4)
        var maskValues = [UInt8](repeating: 0, count: cw * ch)
        let w = original.width
        let xStart = max(0, -tx)
        let xEnd = min(w, cw - tx)
        if xStart < xEnd {
            for sy in 0..<original.height {
                let dy = sy + ty
                guard dy >= 0, dy < ch else { continue }
                let count = xEnd - xStart
                let srcPixel = sy * w + xStart
                let dstPixel = dy * cw + xStart + tx
                subjectPixels.replaceSubrange((dstPixel * 4)..<((dstPixel + count) * 4),
                                              with: original.pixels[(srcPixel * 4)..<((srcPixel + count) * 4)])
                maskValues.replaceSubrange(dstPixel..<(dstPixel + count),
                                           with: mask.values[srcPixel..<(srcPixel + count)])
            }
        }
        return (RGBAImage(width: cw, height: ch, colorSpace: original.colorSpace, pixels: subjectPixels),
                AlphaMask(width: cw, height: ch, values: maskValues))
    }

    // MARK: - 背景レイヤー

    /// 背景素材をキャンバスいっぱいに敷き（はみ出しは切り取る）、ぼかし・明るさ・色温度をかける。
    static func backgroundCIImage(item: BackgroundItem?, library: BackgroundLibrary, canvasSize: CGSize,
                                  adjustments: BackgroundAdjustments, originalImage: CGImage?) -> CIImage {
        let rect = CGRect(origin: .zero, size: canvasSize)
        let shortSide = Double(min(canvasSize.width, canvasSize.height))
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

        var image: CIImage
        switch item?.kind {
        case .image:
            if let item, let url = library.fileURL(for: item), let loaded = CIImage(contentsOf: url) {
                image = aspectFill(loaded, in: rect)
            } else {
                image = CIImage(color: CIColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1, colorSpace: srgb)!)
            }
        case .solid(let color):
            image = CIImage(color: ciColor(color, srgb))
        case .gradient(let top, let bottom):
            let filter = CIFilter.linearGradient()
            filter.point0 = CGPoint(x: 0, y: rect.height)
            filter.color0 = ciColor(top, srgb)
            filter.point1 = CGPoint(x: 0, y: 0)
            filter.color1 = ciColor(bottom, srgb)
            image = filter.outputImage ?? CIImage(color: ciColor(top, srgb))
        case .blurredOriginal:
            if let originalImage {
                image = aspectFill(CIImage(cgImage: originalImage), in: rect)
                    .clampedToExtent()
                    .applyingGaussianBlur(sigma: 0.04 * shortSide)
            } else {
                image = CIImage(color: CIColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1, colorSpace: srgb)!)
            }
        case nil:
            image = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1, colorSpace: srgb)!)
        }
        image = image.cropped(to: rect)

        if adjustments.blur > 0 {
            image = image.clampedToExtent()
                .applyingGaussianBlur(sigma: adjustments.blur * 0.03 * shortSide)
                .cropped(to: rect)
        }
        if adjustments.brightness != 0 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = image
            filter.ev = Float(adjustments.brightness)
            image = filter.outputImage ?? image
        }
        if adjustments.temperature != 0 {
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = image
            filter.neutral = CIVector(x: 6500 + adjustments.temperature * 3000, y: 0)
            filter.targetNeutral = CIVector(x: 6500, y: 0)
            image = filter.outputImage ?? image
        }
        return image.cropped(to: rect)
    }

    /// 作品のマスクを下にずらしてぼかし、背景を暗くする。
    static func applyShadow(to background: CIImage, mask: AlphaMask, shadow: ShadowSettings) -> CIImage {
        guard let maskImage = mask.makeCGImage() else { return background }
        let rect = CGRect(x: 0, y: 0, width: mask.width, height: mask.height)
        let shortSide = Double(min(mask.width, mask.height))
        let offset = shadow.offsetPixels(canvasShortSide: shortSide)
        let sigma = shadow.blurPixels(canvasShortSide: shortSide)

        // マスクは色管理しない（値をそのまま濃さとして使う）。Core Image は y 軸が上向きなので下へは負方向
        let shadowMask = CIImage(cgImage: maskImage, options: [.colorSpace: NSNull()])
            .transformed(by: CGAffineTransform(translationX: 0, y: -offset))
            .applyingGaussianBlur(sigma: sigma)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: shadow.opacity, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: shadow.opacity, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: shadow.opacity, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
            .cropped(to: rect)

        let blend = CIFilter.blendWithMask()
        blend.inputImage = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: rect)
        blend.backgroundImage = background
        blend.maskImage = shadowMask
        return (blend.outputImage ?? background).cropped(to: rect)
    }

    static func renderToPixels(_ image: CIImage, width: Int, height: Int, colorSpace: CGColorSpace) throws -> RGBAImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            ciContext.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 4,
                             bounds: CGRect(x: 0, y: 0, width: width, height: height),
                             format: .RGBA8, colorSpace: colorSpace)
        }
        // 背景は不透明にする
        for i in stride(from: 3, to: pixels.count, by: 4) {
            pixels[i] = 255
        }
        return RGBAImage(width: width, height: height, colorSpace: colorSpace, pixels: pixels)
    }

    /// プレビュー用の背景（長辺 maxDimension 程度に縮小したキャンバス）。
    static func backgroundPreview(item: BackgroundItem?, library: BackgroundLibrary, canvasWidth: Int,
                                  canvasHeight: Int, adjustments: BackgroundAdjustments,
                                  originalImage: CGImage?, maxDimension: Double = 1200) -> CGImage? {
        let factor = min(1, maxDimension / Double(max(canvasWidth, canvasHeight)))
        let size = CGSize(width: (Double(canvasWidth) * factor).rounded(), height: (Double(canvasHeight) * factor).rounded())
        let image = backgroundCIImage(item: item, library: library, canvasSize: size,
                                      adjustments: adjustments, originalImage: originalImage)
        return ciContext.createCGImage(image, from: CGRect(origin: .zero, size: size), format: .RGBA8,
                                       colorSpace: CGColorSpace(name: CGColorSpace.displayP3))
    }

    // MARK: - 透かし

    static let watermarkText = "作品カメラ"

    /// 右下に透かしを入れる。背景レイヤーに描くので作品の画素は変わらない。
    static func drawWatermark(on layer: inout RGBAImage) {
        let shortSide = CGFloat(min(layer.width, layer.height))
        let fontSize = max(14, shortSide * 0.035)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: UIColor.white.withAlphaComponent(0.85),
        ]
        let text = watermarkText as NSString
        let textSize = text.size(withAttributes: attributes)
        let padding = fontSize * 0.5
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: textSize.width + padding * 2, height: textSize.height + padding * 2), format: format)
        let badge = renderer.image { context in
            let shadow = NSShadow()
            shadow.shadowColor = UIColor.black.withAlphaComponent(0.45)
            shadow.shadowBlurRadius = fontSize * 0.25
            var shadowed = attributes
            shadowed[.shadow] = shadow
            text.draw(at: CGPoint(x: padding, y: padding), withAttributes: shadowed)
            _ = context
        }
        guard let badgeImage = badge.cgImage else { return }

        let width = layer.width
        let height = layer.height
        let colorSpace = layer.colorSpace
        let margin = shortSide * 0.03
        layer.pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            let rect = CGRect(x: CGFloat(width) - CGFloat(badgeImage.width) - margin, y: margin,
                              width: CGFloat(badgeImage.width), height: CGFloat(badgeImage.height))
            context.draw(badgeImage, in: rect)
        }
    }

    // MARK: - ヘルパー

    private static func aspectFill(_ image: CIImage, in rect: CGRect) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let scale = max(rect.width / extent.width, rect.height / extent.height)
        let scaled = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale)))
        let dx = (rect.width - extent.width * scale) / 2
        let dy = (rect.height - extent.height * scale) / 2
        return scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
    }

    private static func ciColor(_ color: RGBColor, _ space: CGColorSpace) -> CIColor {
        CIColor(red: color.red, green: color.green, blue: color.blue, alpha: 1, colorSpace: space)
            ?? CIColor(red: color.red, green: color.green, blue: color.blue)
    }
}

enum RendererError: Swift.Error {
    case drawingFailed
}

extension AlphaMask {
    /// 8bit グレースケールの CGImage（色管理なし）。
    func makeCGImage() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(values) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
