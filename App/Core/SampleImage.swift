import CoreGraphics
import Foundation
import ImageIO

/// 同梱のサンプル写真（木のテーブルに編みコースターと刺繍ポーチ）。
/// カメラのないシミュレータとテストで切り抜き以降を確認するために使う。
enum SampleImage {
    static func load() -> CGImage? {
        guard let url = Bundle(for: EditSession.self).url(forResource: "sample_work", withExtension: "jpg"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
