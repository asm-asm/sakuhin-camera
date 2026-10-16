import CoreGraphics
import CoreVideo
import XCTest
@testable import SakuhinCamera

final class SegmentationTests: XCTestCase {
    // MARK: - マスクの量子化

    func testQuantizeKeepsFullAndEmpty() {
        XCTAssertEqual(AlphaMask.quantize(1), 255)
        XCTAssertEqual(AlphaMask.quantize(0), 0)
        XCTAssertEqual(AlphaMask.quantize(0.5), 128)
    }

    func testQuantizeSnapsNearlyOpaqueTo255() {
        // 被写体の内側で Vision が返しがちな 0.99 は作品扱い（255）にする
        XCTAssertEqual(AlphaMask.quantize(0.99), 255)
        XCTAssertEqual(AlphaMask.quantize(0.97), 247)
    }

    func testQuantizeClampsOutOfRange() {
        XCTAssertEqual(AlphaMask.quantize(1.5), 255)
        XCTAssertEqual(AlphaMask.quantize(-0.2), 0)
        XCTAssertEqual(AlphaMask.quantize(.nan), 0)
    }

    func testFloatPixelBufferIsReadRowByRow() throws {
        let buffer = try makeBuffer(width: 3, height: 2, format: kCVPixelFormatType_OneComponent32Float) { row, y in
            let values: [Float] = y == 0 ? [0, 0.5, 1] : [1, 0.25, 0]
            let pointer = row.assumingMemoryBound(to: Float.self)
            for (x, v) in values.enumerated() { pointer[x] = v }
        }

        let mask = try AlphaMask(floatPixelBuffer: buffer)

        XCTAssertEqual(mask.width, 3)
        XCTAssertEqual(mask.height, 2)
        XCTAssertEqual(mask.values, [0, 128, 255, 255, 64, 0])
    }

    func testFloatReaderRejectsOtherFormats() throws {
        let buffer = try makeBuffer(width: 2, height: 2, format: kCVPixelFormatType_OneComponent8) { _, _ in }
        XCTAssertThrowsError(try AlphaMask(floatPixelBuffer: buffer))
    }

    // MARK: - 被写体番号の地図

    func testLabelMapFromPixelBufferAndLookup() throws {
        let buffer = try makeBuffer(width: 4, height: 2, format: kCVPixelFormatType_OneComponent8) { row, y in
            let values: [UInt8] = y == 0 ? [0, 1, 1, 2] : [0, 0, 2, 2]
            let pointer = row.assumingMemoryBound(to: UInt8.self)
            for (x, v) in values.enumerated() { pointer[x] = v }
        }

        let map = try InstanceLabelMap(pixelBuffer: buffer)

        XCTAssertEqual(map.labels, [0, 1, 1, 2, 0, 0, 2, 2])
        XCTAssertNil(map.instance(atNormalized: CGPoint(x: 0.1, y: 0.25)))
        XCTAssertEqual(map.instance(atNormalized: CGPoint(x: 0.3, y: 0.25)), 1)
        XCTAssertEqual(map.instance(atNormalized: CGPoint(x: 0.9, y: 0.9)), 2)
        // 端（1.0）でも範囲外にならない
        XCTAssertEqual(map.instance(atNormalized: CGPoint(x: 1, y: 1)), 2)
    }

    func testOverlayLeavesSelectedSubjectsClear() throws {
        let map = InstanceLabelMap(width: 3, height: 1, labels: [0, 1, 2])

        let overlay = try XCTUnwrap(map.overlayImage(selected: [1]))
        let pixels = try RGBAImage(cgImage: overlay).pixels

        XCTAssertEqual(pixels[3], 153, "背景は暗く")
        XCTAssertEqual(pixels[7], 0, "選択中の被写体は透明")
        XCTAssertEqual(pixels[11], 89, "未選択の被写体はかすませる")
    }

    // MARK: - タップ位置

    func testImageFitCentersImage() {
        let rect = ImageFit.rect(for: CGSize(width: 300, height: 400), in: CGSize(width: 600, height: 600))
        XCTAssertEqual(rect, CGRect(x: 75, y: 0, width: 450, height: 600))
    }

    func testNormalizedPointInsideAndOutsideImage() {
        let image = CGSize(width: 300, height: 400)
        let container = CGSize(width: 600, height: 600)

        let center = ImageFit.normalizedPoint(CGPoint(x: 300, y: 300), imageSize: image, in: container)
        XCTAssertEqual(center, CGPoint(x: 0.5, y: 0.5))
        XCTAssertNil(ImageFit.normalizedPoint(CGPoint(x: 10, y: 300), imageSize: image, in: container))
    }

    // MARK: - Vision（サンプル写真）

    /// 実際の流れ：サンプル写真 → Vision で切り抜き → 合成。作品の画素が元写真と一致すること。
    func testSampleImageSegmentationKeepsSubjectPixels() throws {
        let image = try XCTUnwrap(SampleImage.load(), "サンプル写真が同梱されていない")

        let segmentation: SubjectSegmentation
        do {
            segmentation = try SubjectSegmenter.segment(image)
        } catch SubjectSegmenter.Error.noSubject {
            #if targetEnvironment(simulator)
            throw XCTSkip("シミュレータでは Vision が被写体を返さない（実機で確認する）")
            #else
            XCTFail("サンプル写真から被写体が見つからなかった")
            return
            #endif
        } catch {
            throw XCTSkip("この環境では Vision の切り抜きが使えない: \(error)")
        }
        print("検出した被写体の数: \(segmentation.instances.count)")
        XCTAssertGreaterThanOrEqual(segmentation.instances.count, 1)

        let mask = try segmentation.makeMask(for: segmentation.instances)
        XCTAssertEqual(mask.width, image.width)
        XCTAssertEqual(mask.height, image.height)
        let opaqueCount = mask.values.filter { $0 == 255 }.count
        XCTAssertGreaterThan(opaqueCount, image.width * image.height / 20, "作品部分がほとんどない")

        let original = try RGBAImage(cgImage: image)
        let background = RGBAImage(width: original.width, height: original.height, colorSpace: original.colorSpace,
                                   pixels: [UInt8](repeating: 255, count: original.pixels.count))
        let output = try Compositor.composite(original: original, mask: mask, background: background)

        var mismatches = 0
        for i in 0..<(original.width * original.height) where mask.values[i] == 255 {
            let range = (i * 4)..<(i * 4 + 4)
            if output.pixels[range] != original.pixels[range] { mismatches += 1 }
        }
        XCTAssertEqual(mismatches, 0, "作品の画素が変わった")
    }

    // MARK: - ヘルパー

    private func makeBuffer(width: Int, height: Int, format: OSType,
                            fill: (UnsafeMutableRawPointer, Int) -> Void) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, nil, &buffer)
        let pixelBuffer = try XCTUnwrap(buffer, "CVPixelBufferCreate 失敗: \(status)")
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer))
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<height {
            fill(base.advanced(by: y * rowBytes), y)
        }
        return pixelBuffer
    }
}
