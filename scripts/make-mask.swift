// スクリーンショット用：写真から Vision で被写体マスクを作る（macOS で実行）。
// アプリと同じ VNGenerateForegroundInstanceMaskRequest を使い、値の丸めもアプリと同じにする。
//
// 使い方: swift scripts/make-mask.swift 写真.jpg 出力フォルダ
// 出力: demo_mask.raw / demo_labels.raw（先頭に幅・高さを UInt32 リトルエンディアンで2つ、その後に1画素1バイト）
//       と、確認用の demo_mask.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("使い方: swift make-mask.swift 写真.jpg 出力フォルダ")
    exit(2)
}
let outputDirectory = URL(fileURLWithPath: arguments[2])

/// 色変換が入らないよう、値をそのまま書き出す。
func writeRaw(_ values: [UInt8], width: Int, height: Int, name: String) {
    var data = Data()
    for value in [UInt32(width), UInt32(height)] {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    data.append(contentsOf: values)
    try! data.write(to: outputDirectory.appendingPathComponent(name))
}

func writeGrayPNG(_ values: [UInt8], width: Int, height: Int, to path: String) {
    let provider = CGDataProvider(data: Data(values) as CFData)!
    let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let url = URL(fileURLWithPath: path) as CFURL
    let destination = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, nil)!
let photo = CGImageSourceCreateImageAtIndex(source, 0, nil)!
let request = VNGenerateForegroundInstanceMaskRequest()
let handler = VNImageRequestHandler(cgImage: photo, orientation: .up)
try handler.perform([request])
guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
    print("被写体が見つからなかった")
    exit(1)
}
print("被写体の数: \(observation.allInstances.count)")

// マスク（アプリの AlphaMask.quantize と同じ丸め：250/255 以上は 255）
let maskBuffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
CVPixelBufferLockBaseAddress(maskBuffer, .readOnly)
let mw = CVPixelBufferGetWidth(maskBuffer)
let mh = CVPixelBufferGetHeight(maskBuffer)
let mRow = CVPixelBufferGetBytesPerRow(maskBuffer)
let mBase = CVPixelBufferGetBaseAddress(maskBuffer)!
var mask = [UInt8](repeating: 0, count: mw * mh)
for y in 0..<mh {
    let row = mBase.advanced(by: y * mRow).assumingMemoryBound(to: Float.self)
    for x in 0..<mw {
        let v = row[x]
        let scaled = v.isFinite ? min(max(v, 0), 1) * 255 : 0
        mask[y * mw + x] = scaled >= 250 ? 255 : UInt8(scaled.rounded())
    }
}
CVPixelBufferUnlockBaseAddress(maskBuffer, .readOnly)
writeRaw(mask, width: mw, height: mh, name: "demo_mask.raw")
writeGrayPNG(mask, width: mw, height: mh, to: outputDirectory.appendingPathComponent("demo_mask.png").path)
print("マスク: \(mw)x\(mh)、作品の画素 \(mask.filter { $0 == 255 }.count)")

// 被写体番号の地図（タップ判定・選択表示用）
let labelBuffer = observation.instanceMask
CVPixelBufferLockBaseAddress(labelBuffer, .readOnly)
let lw = CVPixelBufferGetWidth(labelBuffer)
let lh = CVPixelBufferGetHeight(labelBuffer)
let lRow = CVPixelBufferGetBytesPerRow(labelBuffer)
let lBase = CVPixelBufferGetBaseAddress(labelBuffer)!
var labels = [UInt8](repeating: 0, count: lw * lh)
for y in 0..<lh {
    let row = lBase.advanced(by: y * lRow).assumingMemoryBound(to: UInt8.self)
    for x in 0..<lw {
        labels[y * lw + x] = row[x]
    }
}
CVPixelBufferUnlockBaseAddress(labelBuffer, .readOnly)
writeRaw(labels, width: lw, height: lh, name: "demo_labels.raw")
print("ラベル: \(lw)x\(lh)")
