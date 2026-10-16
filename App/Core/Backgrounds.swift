import CoreGraphics
import Foundation
import ImageIO

/// 同梱背景の1件。`Backgrounds/manifest.json` から読み込む。
/// 画像ファイル（file）のほか、単色（color）・グラデーション（gradient）・元写真のぼかし（blurOriginal）はコードで生成する。
struct BackgroundItem: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let category: String
    let file: String?
    let color: String?
    let gradient: [String]?
    let blurOriginal: Bool?
    let premium: Bool
    let aiGenerated: Bool

    enum Kind: Equatable {
        case image(file: String)
        case solid(RGBColor)
        case gradient(top: RGBColor, bottom: RGBColor)
        case blurredOriginal
    }

    var kind: Kind? {
        if let file { return .image(file: file) }
        if let color, let rgb = RGBColor(hex: color) { return .solid(rgb) }
        if let gradient, gradient.count == 2,
           let top = RGBColor(hex: gradient[0]), let bottom = RGBColor(hex: gradient[1]) {
            return .gradient(top: top, bottom: bottom)
        }
        if blurOriginal == true { return .blurredOriginal }
        return nil
    }
}

struct RGBColor: Equatable {
    let red: Double
    let green: Double
    let blue: Double

    /// "#RRGGBB" 形式。
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        red = Double((value >> 16) & 0xFF) / 255
        green = Double((value >> 8) & 0xFF) / 255
        blue = Double(value & 0xFF) / 255
    }
}

/// 背景一覧。カテゴリは manifest に出てくる順に並べる。
final class BackgroundLibrary {
    static let shared = BackgroundLibrary()

    let items: [BackgroundItem]
    let directory: URL?

    static let categoryNames: [String: String] = [
        "wood": "木",
        "fabric": "布",
        "cafe": "カフェ",
        "outdoor": "屋外",
        "plain": "単色・グラデーション",
    ]

    init(bundle: Bundle = Bundle(for: EditSession.self)) {
        let directory = bundle.url(forResource: "Backgrounds", withExtension: nil)
        self.directory = directory
        if let url = directory?.appendingPathComponent("manifest.json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([BackgroundItem].self, from: data) {
            items = decoded.filter { $0.kind != nil }
        } else {
            items = []
        }
    }

    var categories: [String] {
        var seen: [String] = []
        for item in items where !seen.contains(item.category) {
            seen.append(item.category)
        }
        return seen
    }

    func items(in category: String) -> [BackgroundItem] {
        items.filter { $0.category == category }
    }

    func item(id: String?) -> BackgroundItem? {
        guard let id else { return nil }
        return items.first { $0.id == id }
    }

    var defaultItem: BackgroundItem? {
        items.first { !$0.premium }
    }

    func fileURL(for item: BackgroundItem) -> URL? {
        guard case .image(let file) = item.kind else { return nil }
        return directory?.appendingPathComponent(file)
    }

    static func displayName(ofCategory category: String) -> String {
        categoryNames[category] ?? category
    }
}
