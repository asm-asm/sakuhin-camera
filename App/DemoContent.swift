import CoreGraphics
import Foundation
import ImageIO

/// App Store 用スクリーンショットの撮影モード（CI のシミュレータ専用）。
///
/// 起動引数 `-demoScene <preview|cutout|background|export>` を付けたときだけ有効。
/// シミュレータでは Vision の切り抜きが動かないため、本物の写真と、macOS 上で同じ Vision 処理をかけて作った
/// マスク（scripts/make-mask.swift の .raw）をアプリの Documents に置いて読み込む。画面と合成処理はすべて本物を使う。
struct DemoContent {
    enum Scene: String {
        case preview
        case cutout
        case background
        case export
    }

    let photo: CGImage
    let mask: AlphaMask
    let labels: InstanceLabelMap

    static let scene: Scene? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-demoScene"), index + 1 < arguments.count else { return nil }
        return Scene(rawValue: arguments[index + 1])
    }()

    static let isPremium = ProcessInfo.processInfo.arguments.contains("-demoPremium")

    static let backgroundID: String? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-demoBackground"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }()

    static let shared: DemoContent? = scene == nil ? nil : load()

    private static func load() -> DemoContent? {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let photo = image(documents.appendingPathComponent("demo_photo.jpg")),
              let mask = raw(documents.appendingPathComponent("demo_mask.raw")),
              let labels = raw(documents.appendingPathComponent("demo_labels.raw"))
        else { return nil }
        guard mask.width == photo.width, mask.height == photo.height else { return nil }
        return DemoContent(photo: photo,
                           mask: AlphaMask(width: mask.width, height: mask.height, values: mask.values),
                           labels: InstanceLabelMap(width: labels.width, height: labels.height, labels: labels.values))
    }

    private static func image(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// scripts/make-mask.swift が書き出した生データ（幅・高さ・1画素1バイト）。
    private static func raw(_ url: URL) -> (width: Int, height: Int, values: [UInt8])? {
        guard let data = try? Data(contentsOf: url), data.count >= 8 else { return nil }
        let bytes = [UInt8](data)
        func uint32(at offset: Int) -> Int {
            Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }
        let w = uint32(at: 0)
        let h = uint32(at: 4)
        guard w > 0, h > 0, bytes.count == 8 + w * h else { return nil }
        return (w, h, Array(bytes[8...]))
    }
}
