import CoreGraphics
import CoreML
import CoreVideo
import Vision

/// Vision の被写体切り抜き（端末内処理）。
/// 元写真は向きを正規化済み（.up）の CGImage を渡すこと。マスクも同じ向き・同じ大きさで返る。
enum SubjectSegmenter {
    enum Error: Swift.Error {
        case noSubject
    }

    static func segment(_ image: CGImage) throws -> SubjectSegmentation {
        let request = VNGenerateForegroundInstanceMaskRequest()
        #if targetEnvironment(simulator)
        // シミュレータには Neural Engine がないので CPU で動かす
        if let cpu = MLComputeDevice.allComputeDevices.first(where: { if case .cpu = $0 { return true } else { return false } }) {
            for stage in try request.supportedComputeStageDevices().keys {
                request.setComputeDevice(cpu, for: stage)
            }
        }
        #endif
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw Error.noSubject
        }
        let labels = try InstanceLabelMap(pixelBuffer: observation.instanceMask)
        return SubjectSegmentation(
            labels: labels,
            instances: observation.allInstances,
            imageWidth: image.width,
            imageHeight: image.height,
            observation: observation,
            handler: handler
        )
    }
}

/// 切り抜き結果。選んだ被写体だけのマスクを元写真と同じ解像度で作れる。
struct SubjectSegmentation {
    /// タップ判定・選択表示用の低解像度ラベル（0 = 背景、1〜 = 被写体番号）。
    let labels: InstanceLabelMap
    let instances: IndexSet
    let imageWidth: Int
    let imageHeight: Int
    fileprivate let observation: VNInstanceMaskObservation
    fileprivate let handler: VNImageRequestHandler

    enum Error: Swift.Error {
        case maskSizeMismatch
    }

    func makeMask(for selected: IndexSet) throws -> AlphaMask {
        let buffer = try observation.generateScaledMaskForImage(forInstances: selected, from: handler)
        let mask = try AlphaMask(floatPixelBuffer: buffer)
        guard mask.width == imageWidth, mask.height == imageHeight else { throw Error.maskSizeMismatch }
        return mask
    }
}

enum PixelBufferError: Swift.Error {
    case unsupportedFormat
    case noBaseAddress
}

/// 被写体番号の地図。Vision の instanceMask（8bit・1チャンネル）から作る。
struct InstanceLabelMap {
    let width: Int
    let height: Int
    let labels: [UInt8]

    init(width: Int, height: Int, labels: [UInt8]) {
        precondition(labels.count == width * height)
        self.width = width
        self.height = height
        self.labels = labels
    }

    init(pixelBuffer buffer: CVPixelBuffer) throws {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8 else {
            throw PixelBufferError.unsupportedFormat
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw PixelBufferError.noBaseAddress }

        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var labels = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w {
                labels[y * w + x] = row[x]
            }
        }
        self.init(width: w, height: h, labels: labels)
    }

    /// 正規化座標（左上 0,0 〜 右下 1,1）にある被写体番号。背景なら nil。
    func instance(atNormalized point: CGPoint) -> Int? {
        let x = min(max(Int(point.x * CGFloat(width)), 0), width - 1)
        let y = min(max(Int(point.y * CGFloat(height)), 0), height - 1)
        let label = Int(labels[y * width + x])
        return label == 0 ? nil : label
    }

    /// 選択表示用の重ね画像。選択中＝透明、未選択の被写体＝白くかすませる、背景＝暗くする。
    func overlayImage(selected: IndexSet) -> CGImage? {
        // プリマルチプライ済みの (グレー, α)
        let background: (UInt8, UInt8) = (0, 153)
        let unselected: (UInt8, UInt8) = (89, 89)
        let clear: (UInt8, UInt8) = (0, 0)

        var table = [(UInt8, UInt8)](repeating: unselected, count: 256)
        table[0] = background
        for index in selected where index > 0 && index < 256 {
            table[index] = clear
        }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let (gray, alpha) = table[Int(labels[i])]
            pixels[i * 4] = gray
            pixels[i * 4 + 1] = gray
            pixels[i * 4 + 2] = gray
            pixels[i * 4 + 3] = alpha
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        return RGBAImage(width: width, height: height, colorSpace: space, pixels: pixels).makeCGImage()
    }
}

extension AlphaMask {
    /// Vision の柔らかいマスク（0〜1 の Float）を 8bit にする。
    init(floatPixelBuffer buffer: CVPixelBuffer) throws {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float else {
            throw PixelBufferError.unsupportedFormat
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw PixelBufferError.noBaseAddress }

        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var values = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
            for x in 0..<w {
                values[y * w + x] = Self.quantize(row[x])
            }
        }
        self.init(width: w, height: h, values: values)
    }

    /// 被写体の内側でも Vision の値は 0.99 程度になることがあり、そのままだと作品に背景がわずかに混ざる。
    /// ほぼ 1 の値は 255 に寄せて、作品の画素が元写真と完全一致するようにする。
    static let snapToOpaqueThreshold: Float = 250

    static func quantize(_ value: Float) -> UInt8 {
        guard value.isFinite else { return 0 }
        let scaled = min(max(value, 0), 1) * 255
        if scaled >= snapToOpaqueThreshold { return 255 }
        return UInt8(scaled.rounded())
    }
}
