import CoreGraphics
import XCTest
@testable import SakuhinCamera

/// 最重要ルール「マスク=1 の画素は元写真と完全一致」を確認するテスト。
final class CompositorTests: XCTestCase {
    private let width = 64
    private let height = 48

    func testFullMaskPixelsMatchOriginalExactly() throws {
        var rng = SeededGenerator(seed: 1)
        let original = makeOpaqueImage(colorSpace: displayP3, rng: &rng)
        let background = makeOpaqueImage(colorSpace: displayP3, rng: &rng)
        let mask = makeMask(rng: &rng)

        let output = try Compositor.composite(original: original, mask: mask, background: background)

        assertSubjectUnchanged(output: output, original: original, mask: mask)
    }

    func testZeroMaskPixelsMatchBackground() throws {
        var rng = SeededGenerator(seed: 2)
        let original = makeOpaqueImage(colorSpace: displayP3, rng: &rng)
        let background = makeOpaqueImage(colorSpace: displayP3, rng: &rng)
        let mask = makeMask(rng: &rng)

        let output = try Compositor.composite(original: original, mask: mask, background: background)

        for i in 0..<(width * height) where mask.values[i] == 0 {
            XCTAssertEqual(pixel(output.pixels, i), pixel(background.pixels, i), "背景画素 \(i)")
        }
    }

    func testPartialMaskBlendsBetweenBackgroundAndOriginal() throws {
        let space = displayP3
        let original = RGBAImage(width: 1, height: 1, colorSpace: space, pixels: [200, 100, 0, 255])
        let background = RGBAImage(width: 1, height: 1, colorSpace: space, pixels: [0, 100, 200, 255])
        let mask = AlphaMask(width: 1, height: 1, values: [128])

        let output = try Compositor.composite(original: original, mask: mask, background: background)

        XCTAssertEqual(output.pixels, [100, 100, 100, 255])
    }

    func testSizeMismatchThrows() {
        let space = displayP3
        let original = RGBAImage(width: 2, height: 1, colorSpace: space, pixels: [UInt8](repeating: 255, count: 8))
        let background = RGBAImage(width: 1, height: 1, colorSpace: space, pixels: [UInt8](repeating: 255, count: 4))
        let mask = AlphaMask(width: 2, height: 1, values: [255, 255])

        XCTAssertThrowsError(try Compositor.composite(original: original, mask: mask, background: background)) { error in
            XCTAssertEqual(error as? Compositor.Error, .sizeMismatch)
        }
    }

    /// 実際の流れ（P3 の写真 → 画素化 → sRGB 背景を P3 に変換して合成 → CGImage に戻す）でも作品の画素が変わらないこと。
    func testSubjectPixelsSurviveCGImageRoundTrip() throws {
        var rng = SeededGenerator(seed: 3)
        let source = makeOpaqueImage(colorSpace: displayP3, rng: &rng)
        let photo = try XCTUnwrap(source.makeCGImage())

        let original = try RGBAImage(cgImage: photo)
        XCTAssertEqual(original.colorSpace.name as String?, CGColorSpace.displayP3 as String)
        XCTAssertEqual(original.pixels, source.pixels, "写真の読み込みで画素が変わった")

        let srgbBackground = try XCTUnwrap(makeOpaqueImage(colorSpace: srgb, rng: &rng).makeCGImage())
        let background = try RGBAImage(cgImage: srgbBackground, colorSpace: original.colorSpace)
        let mask = makeMask(rng: &rng)

        let composited = try Compositor.composite(original: original, mask: mask, background: background)
        let exported = try XCTUnwrap(composited.makeCGImage())
        let reread = try RGBAImage(cgImage: exported)

        assertSubjectUnchanged(output: reread, original: source, mask: mask)
    }

    // MARK: - ヘルパー

    private var displayP3: CGColorSpace { CGColorSpace(name: CGColorSpace.displayP3)! }
    private var srgb: CGColorSpace { CGColorSpace(name: CGColorSpace.sRGB)! }

    private func assertSubjectUnchanged(output: RGBAImage, original: RGBAImage, mask: AlphaMask,
                                        file: StaticString = #filePath, line: UInt = #line) {
        var subjectCount = 0
        var mismatches = 0
        for i in 0..<(width * height) where mask.values[i] == 255 {
            subjectCount += 1
            if pixel(output.pixels, i) != pixel(original.pixels, i) { mismatches += 1 }
        }
        XCTAssertGreaterThan(subjectCount, 0, "テスト用マスクに被写体画素がない", file: file, line: line)
        XCTAssertEqual(mismatches, 0, "作品の画素が \(mismatches)/\(subjectCount) 個変わった", file: file, line: line)
    }

    private func pixel(_ pixels: [UInt8], _ index: Int) -> [UInt8] {
        Array(pixels[(index * 4)..<(index * 4 + 4)])
    }

    private func makeOpaqueImage(colorSpace: CGColorSpace, rng: inout SeededGenerator) -> RGBAImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            pixels[i * 4] = UInt8.random(in: 0...255, using: &rng)
            pixels[i * 4 + 1] = UInt8.random(in: 0...255, using: &rng)
            pixels[i * 4 + 2] = UInt8.random(in: 0...255, using: &rng)
        }
        return RGBAImage(width: width, height: height, colorSpace: colorSpace, pixels: pixels)
    }

    /// 中央の楕円を 255、外側を 0、境界付近を中間値にしたマスク（実際の切り抜きに近い形）。
    private func makeMask(rng: inout SeededGenerator) -> AlphaMask {
        var values = [UInt8](repeating: 0, count: width * height)
        let cx = Double(width) / 2, cy = Double(height) / 2
        let rx = Double(width) / 3, ry = Double(height) / 3
        for y in 0..<height {
            for x in 0..<width {
                let d = pow((Double(x) - cx) / rx, 2) + pow((Double(y) - cy) / ry, 2)
                if d < 0.8 {
                    values[y * width + x] = 255
                } else if d < 1.2 {
                    values[y * width + x] = UInt8.random(in: 1...254, using: &rng)
                }
            }
        }
        return AlphaMask(width: width, height: height, values: values)
    }
}

/// 再現性のある乱数（SplitMix64）。
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
