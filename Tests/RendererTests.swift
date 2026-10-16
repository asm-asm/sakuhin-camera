import CoreGraphics
import CoreImage
import XCTest
@testable import SakuhinCamera

/// 書き出し処理のテスト。特に「調整・影・透かしを入れても作品の画素は元写真と一致する」こと。
final class RendererTests: XCTestCase {
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    private let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!

    // MARK: - キャンバス

    func testCanvasContainsWholePhoto() {
        XCTAssertTrue(Canvas.size(imageWidth: 3000, imageHeight: 4000, ratio: .original) == (3000, 4000))
        XCTAssertTrue(Canvas.size(imageWidth: 3000, imageHeight: 4000, ratio: .square) == (4000, 4000))
        XCTAssertTrue(Canvas.size(imageWidth: 3000, imageHeight: 4000, ratio: .portrait4x5) == (3200, 4000))
        XCTAssertTrue(Canvas.size(imageWidth: 3000, imageHeight: 4000, ratio: .story9x16) == (3000, 5333))
        XCTAssertTrue(Canvas.size(imageWidth: 4000, imageHeight: 3000, ratio: .square) == (4000, 4000))
    }

    // MARK: - 作品の配置

    func testUnscaledPlacementCopiesPixelsExactly() throws {
        var rng = SeededGenerator(seed: 11)
        let original = makeImage(width: 40, height: 30, rng: &rng)
        let mask = makeMask(width: 40, height: 30)
        var transform = SubjectTransform()
        transform.offset = CGSize(width: 3, height: -2)

        let placed = try Renderer.placeSubject(original: original, originalImage: nil, mask: mask,
                                               canvasWidth: 50, canvasHeight: 50, transform: transform)

        // 中心 (25+3, 25-2) に 40x30 を置くので左上は (8, 8)
        for y in 0..<30 {
            for x in 0..<40 {
                let src = y * 40 + x
                let dst = (y + 8) * 50 + (x + 8)
                XCTAssertEqual(placed.mask.values[dst], mask.values[src])
                XCTAssertEqual(placed.subject.pixels[(dst * 4)..<(dst * 4 + 4)], original.pixels[(src * 4)..<(src * 4 + 4)])
            }
        }
        XCTAssertEqual(placed.mask.values[0], 0, "作品の外は背景")
    }

    func testScaledPlacementShrinksMask() throws {
        var rng = SeededGenerator(seed: 12)
        let original = makeImage(width: 80, height: 80, rng: &rng)
        let mask = AlphaMask(width: 80, height: 80, values: [UInt8](repeating: 255, count: 80 * 80))
        var transform = SubjectTransform()
        transform.scale = 0.5

        let placed = try Renderer.placeSubject(original: original, originalImage: nil, mask: mask,
                                               canvasWidth: 80, canvasHeight: 80, transform: transform)

        let covered = placed.mask.values.filter { $0 > 127 }.count
        XCTAssertEqual(Double(covered), 1600, accuracy: 200, "半分の大きさ（面積1/4）になる")
        XCTAssertEqual(placed.mask.values[0], 0)
        XCTAssertEqual(placed.mask.values[40 * 80 + 40], 255)
    }

    // MARK: - 最終画像（最重要ルール）

    func testFullRenderKeepsSubjectPixelsWithAdjustmentsShadowAndWatermark() throws {
        var rng = SeededGenerator(seed: 13)
        let original = makeImage(width: 120, height: 90, rng: &rng, colorSpace: displayP3)
        let originalImage = try XCTUnwrap(original.makeCGImage())
        let mask = makeMask(width: 120, height: 90)

        var composition = Composition()
        composition.ratio = .square
        composition.adjustments = BackgroundAdjustments(brightness: 0.6, temperature: -0.8, blur: 0.5)
        composition.shadow = ShadowSettings(isEnabled: true, opacity: 0.9, blur: 0.7, offset: 1)
        let background = try decodeItem(#"{"id":"g","name":"g","category":"plain","gradient":["#FF8800","#2244FF"],"premium":false,"aiGenerated":false}"#)

        let output = try Renderer.render(original: original, originalImage: originalImage, mask: mask,
                                         background: background, library: BackgroundLibrary.shared,
                                         composition: composition, watermark: true)

        // 120x90 → 正方形 120x120。縦に (120-90)/2 = 15 ずれる
        XCTAssertEqual(output.image.width, 120)
        XCTAssertEqual(output.image.height, 120)
        var subjectCount = 0
        var mismatches = 0
        for y in 0..<90 {
            for x in 0..<120 where mask.values[y * 120 + x] == 255 {
                subjectCount += 1
                let src = y * 120 + x
                let dst = (y + 15) * 120 + x
                if output.image.pixels[(dst * 4)..<(dst * 4 + 4)] != original.pixels[(src * 4)..<(src * 4 + 4)] {
                    mismatches += 1
                }
            }
        }
        XCTAssertGreaterThan(subjectCount, 0)
        XCTAssertEqual(mismatches, 0, "作品の画素が \(mismatches)/\(subjectCount) 個変わった")
        XCTAssertEqual(output.image.colorSpace.name as String?, CGColorSpace.displayP3 as String)
    }

    // MARK: - 背景レイヤー

    /// Core Image の上下（y 軸）が書き出しで逆にならないこと。
    func testGradientTopColorIsAtTop() throws {
        let item = try decodeItem(#"{"id":"g","name":"g","category":"plain","gradient":["#FF0000","#0000FF"],"premium":false,"aiGenerated":false}"#)
        let image = Renderer.backgroundCIImage(item: item, library: BackgroundLibrary.shared,
                                               canvasSize: CGSize(width: 10, height: 20),
                                               adjustments: BackgroundAdjustments(), originalImage: nil)
        let pixels = try Renderer.renderToPixels(image, width: 10, height: 20, colorSpace: srgb).pixels

        let top = 0
        let bottom = 19 * 10 * 4
        XCTAssertGreaterThan(pixels[top], pixels[top + 2], "上は赤")
        XCTAssertGreaterThan(pixels[bottom + 2], pixels[bottom], "下は青")
    }

    func testTemperatureWarmsAndCools() throws {
        let item = try decodeItem(#"{"id":"s","name":"s","category":"plain","color":"#999999","premium":false,"aiGenerated":false}"#)
        func render(_ temperature: Double) throws -> [UInt8] {
            let image = Renderer.backgroundCIImage(item: item, library: BackgroundLibrary.shared,
                                                   canvasSize: CGSize(width: 4, height: 4),
                                                   adjustments: BackgroundAdjustments(temperature: temperature),
                                                   originalImage: nil)
            return try Renderer.renderToPixels(image, width: 4, height: 4, colorSpace: srgb).pixels
        }
        let warm = try render(1)
        let cool = try render(-1)
        XCTAssertGreaterThan(warm[0], warm[2], "暖かい（赤みが強い）")
        XCTAssertGreaterThan(cool[2], cool[0], "冷たい（青みが強い）")
    }

    func testShadowFallsBelowSubject() throws {
        var values = [UInt8](repeating: 0, count: 100 * 100)
        for y in 40..<60 {
            for x in 40..<60 {
                values[y * 100 + x] = 255
            }
        }
        let mask = AlphaMask(width: 100, height: 100, values: values)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let shadowed = Renderer.applyShadow(to: white, mask: mask,
                                            shadow: ShadowSettings(isEnabled: true, opacity: 1, blur: 0, offset: 1))
        let pixels = try Renderer.renderToPixels(shadowed, width: 100, height: 100, colorSpace: srgb).pixels

        let below = (62 * 100 + 50) * 4
        let above = (37 * 100 + 50) * 4
        XCTAssertLessThan(pixels[below], 128, "作品の下に影が落ちる")
        XCTAssertGreaterThan(pixels[above], 240, "作品の上には影が出ない")
    }

    func testCaptionMentionsAIOnlyForAIBackgrounds() {
        XCTAssertEqual(AppText.caption(aiGeneratedBackground: true), "作品は無加工・背景は差し替え（AI生成背景）")
        XCTAssertEqual(AppText.caption(aiGeneratedBackground: false), "作品は無加工・背景は差し替え")
    }

    func testTransformSnapsToUnscaled() {
        var transform = SubjectTransform()
        transform.scale = 1.02
        transform.rotation = 0.01
        XCTAssertTrue(transform.snapped().isUnscaled)

        transform.scale = 1.2
        XCTAssertFalse(transform.snapped().isUnscaled)
    }

    // MARK: - ヘルパー

    private func decodeItem(_ json: String) throws -> BackgroundItem {
        try JSONDecoder().decode(BackgroundItem.self, from: Data(json.utf8))
    }

    private func makeImage(width: Int, height: Int, rng: inout SeededGenerator,
                           colorSpace: CGColorSpace? = nil) -> RGBAImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            pixels[i * 4] = UInt8.random(in: 0...255, using: &rng)
            pixels[i * 4 + 1] = UInt8.random(in: 0...255, using: &rng)
            pixels[i * 4 + 2] = UInt8.random(in: 0...255, using: &rng)
        }
        return RGBAImage(width: width, height: height, colorSpace: colorSpace ?? srgb, pixels: pixels)
    }

    /// 中央の楕円が 255、縁が中間値、外が 0。
    private func makeMask(width: Int, height: Int) -> AlphaMask {
        var values = [UInt8](repeating: 0, count: width * height)
        let cx = Double(width) / 2, cy = Double(height) / 2
        for y in 0..<height {
            for x in 0..<width {
                let d = pow((Double(x) - cx) / (Double(width) / 3), 2) + pow((Double(y) - cy) / (Double(height) / 3), 2)
                if d < 0.8 {
                    values[y * width + x] = 255
                } else if d < 1.2 {
                    values[y * width + x] = UInt8((1.2 - d) / 0.4 * 254)
                }
            }
        }
        return AlphaMask(width: width, height: height, values: values)
    }
}
