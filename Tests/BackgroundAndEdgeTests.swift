import CoreGraphics
import XCTest
@testable import SakuhinCamera

final class BackgroundLibraryTests: XCTestCase {
    func testManifestLoadsAndEveryFileIsBundled() throws {
        let library = BackgroundLibrary.shared
        XCTAssertFalse(library.items.isEmpty, "manifest.json が読めない")
        XCTAssertEqual(Set(library.items.map(\.id)).count, library.items.count, "id が重複している")
        for item in library.items {
            if case .image = item.kind {
                let url = try XCTUnwrap(library.fileURL(for: item))
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(item.id) の画像がない")
            }
        }
    }

    func testFreeBackgroundsExistAndDefaultIsFree() throws {
        let library = BackgroundLibrary.shared
        let item = try XCTUnwrap(library.defaultItem)
        XCTAssertFalse(item.premium)
        XCTAssertTrue(library.items.contains { $0.premium }, "有料背景がない")
    }

    func testCategoriesKeepManifestOrder() {
        XCTAssertEqual(BackgroundLibrary.shared.categories, ["wood", "fabric", "cafe", "outdoor", "plain"])
    }

    func testGeneratedKinds() throws {
        func decode(_ json: String) throws -> BackgroundItem {
            try JSONDecoder().decode(BackgroundItem.self, from: Data(json.utf8))
        }
        let solid = try decode(##"{"id":"a","name":"a","category":"plain","color":"#FF8000","premium":false,"aiGenerated":false}"##)
        XCTAssertEqual(solid.kind, .solid(try XCTUnwrap(RGBColor(hex: "#FF8000"))))
        let blur = try decode(##"{"id":"b","name":"b","category":"plain","blurOriginal":true,"premium":false,"aiGenerated":false}"##)
        XCTAssertEqual(blur.kind, .blurredOriginal)
        let broken = try decode(##"{"id":"c","name":"c","category":"plain","color":"red","premium":false,"aiGenerated":false}"##)
        XCTAssertNil(broken.kind)
    }

    func testHexColor() throws {
        let color = try XCTUnwrap(RGBColor(hex: "#336699"))
        XCTAssertEqual(color.red, 0x33 / 255, accuracy: 1e-9)
        XCTAssertEqual(color.green, 0x66 / 255, accuracy: 1e-9)
        XCTAssertEqual(color.blue, 0x99 / 255, accuracy: 1e-9)
        XCTAssertNil(RGBColor(hex: "#12345"))
    }
}

final class EdgeRefinerTests: XCTestCase {
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// 左が暗く右が明るいガイドと、x = 50 で切り替わるマスク。
    private func stepImages(maskEdge: Int, guideEdge: Int, flatGuide: Bool = false) -> (AlphaMask, RGBAImage) {
        let w = 100, h = 60
        var values = [UInt8](repeating: 0, count: w * h)
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                values[y * w + x] = x >= maskEdge ? 255 : 0
                let v: UInt8 = flatGuide ? 128 : (x >= guideEdge ? 210 : 40)
                pixels[(y * w + x) * 4] = v
                pixels[(y * w + x) * 4 + 1] = v
                pixels[(y * w + x) * 4 + 2] = v
            }
        }
        return (AlphaMask(width: w, height: h, values: values), RGBAImage(width: w, height: h, colorSpace: srgb, pixels: pixels))
    }

    func testFarFromEdgeIsUnchanged() {
        let (mask, guide) = stepImages(maskEdge: 50, guideEdge: 50)
        let result = EdgeRefiner.feather(mask: mask, guide: guide, radius: 8)
        for y in 0..<60 {
            for x in [0, 5, 10, 90, 95, 99] {
                XCTAssertEqual(result.values[y * 100 + x], mask.values[y * 100 + x], "(\(x), \(y))")
            }
        }
    }

    func testFlatGuideSoftensEdge() {
        let (mask, guide) = stepImages(maskEdge: 50, guideEdge: 50, flatGuide: true)
        let result = EdgeRefiner.feather(mask: mask, guide: guide, radius: 8)
        let row = Array(result.values[(30 * 100)..<(31 * 100)])
        XCTAssertTrue(row[44..<56].contains { $0 > 20 && $0 < 235 }, "縁が中間値にならない: \(row[40..<60])")
    }

    /// ガイドの境目に沿うので、ただのぼかしより元の境目をくっきり保つ。
    func testEdgeFollowsGuide() {
        let (mask, guide) = stepImages(maskEdge: 50, guideEdge: 50)
        let (_, flat) = stepImages(maskEdge: 50, guideEdge: 50, flatGuide: true)
        let guided = EdgeRefiner.feather(mask: mask, guide: guide, radius: 8)
        let blurred = EdgeRefiner.feather(mask: mask, guide: flat, radius: 8)

        func error(_ result: AlphaMask) -> Int {
            (0..<(100 * 60)).reduce(0) { $0 + abs(Int(result.values[$1]) - Int(mask.values[$1])) }
        }
        XCTAssertLessThan(error(guided), error(blurred) / 2)
    }

    func testPaintAndUndo() {
        var mask = AlphaMask(width: 50, height: 50, values: [UInt8](repeating: 0, count: 2500))
        var stroke = MaskStroke()
        mask.paint(from: CGPoint(x: 10, y: 25), to: CGPoint(x: 40, y: 25), radius: 5, add: true, recordingInto: &stroke)

        XCTAssertEqual(mask.values[25 * 50 + 25], 255)
        XCTAssertEqual(mask.values[5 * 50 + 25], 0)
        XCTAssertFalse(stroke.indices.isEmpty)

        var erase = MaskStroke()
        mask.paint(from: CGPoint(x: 25, y: 25), to: CGPoint(x: 25, y: 25), radius: 3, add: false, recordingInto: &erase)
        XCTAssertEqual(mask.values[25 * 50 + 25], 0)

        mask.undo(erase)
        XCTAssertEqual(mask.values[25 * 50 + 25], 255)
        mask.undo(stroke)
        XCTAssertTrue(mask.values.allSatisfy { $0 == 0 })
    }

    func testDownscaleKeepsAspect() {
        let mask = AlphaMask(width: 4000, height: 3000, values: [UInt8](repeating: 255, count: 12_000_000))
        let small = mask.downscaled(maxDimension: 1400)
        XCTAssertEqual(small.width, 1400)
        XCTAssertEqual(small.height, 1050)
    }

    func testSoftnessRadiusScalesWithPhoto() {
        XCTAssertEqual(EdgeSoftness.none.radius(forLongSide: 4032), 0)
        XCTAssertEqual(EdgeSoftness.medium.radius(forLongSide: 4032), 8)
        XCTAssertEqual(EdgeSoftness.medium.radius(forLongSide: 2016), 4)
    }
}
