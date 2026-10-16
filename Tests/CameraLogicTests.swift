import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SakuhinCamera

/// カメラ周りのうち、実機がなくても確かめられる処理（写真の向き補正・水平ガイド）。
final class CameraLogicTests: XCTestCase {
    // MARK: - 写真の向き補正

    // 保存データ（幅3・高さ2）:
    //   A B C
    //   D E F
    private let a: UInt8 = 10, b: UInt8 = 20, c: UInt8 = 30, d: UInt8 = 40, e: UInt8 = 50, f: UInt8 = 60

    private func stored() -> RGBAImage {
        RGBAImage(width: 3, height: 2, colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
                  pixels: [a, b, c, d, e, f].flatMap { [$0, 0, 0, 255] })
    }

    private func reds(_ image: RGBAImage) -> [UInt8] {
        stride(from: 0, to: image.pixels.count, by: 4).map { image.pixels[$0] }
    }

    func testUpIsUnchanged() {
        let image = stored().oriented(.up)
        XCTAssertEqual(reds(image), [a, b, c, d, e, f])
    }

    func testRightRotatesClockwise() {
        // 縦持ちで撮った写真（iPhone の標準）。右に90°回して表示する
        let image = stored().oriented(.right)
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 3)
        XCTAssertEqual(reds(image), [d, a, e, b, f, c])
    }

    func testLeftRotatesCounterClockwise() {
        let image = stored().oriented(.left)
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 3)
        XCTAssertEqual(reds(image), [c, f, b, e, a, d])
    }

    func testDownRotates180() {
        XCTAssertEqual(reds(stored().oriented(.down)), [f, e, d, c, b, a])
    }

    func testMirroredOrientations() {
        XCTAssertEqual(reds(stored().oriented(.upMirrored)), [c, b, a, f, e, d])
        XCTAssertEqual(reds(stored().oriented(.downMirrored)), [d, e, f, a, b, c])
        XCTAssertEqual(reds(stored().oriented(.leftMirrored)), [a, d, b, e, c, f])
        XCTAssertEqual(reds(stored().oriented(.rightMirrored)), [f, c, e, b, d, a])
    }

    func testOrientationKeepsColorSpaceAndValues() {
        let image = stored().oriented(.right)
        XCTAssertEqual(image.colorSpace.name as String?, CGColorSpace.displayP3 as String)
        XCTAssertEqual(Set(image.pixels), Set(stored().pixels), "並べ替え以外で値が変わった")
    }

    /// 向き情報つきで保存した写真データを読み込むと、正しい向きになること。
    func testDecoderAppliesExifOrientation() throws {
        let source = try XCTUnwrap(stored().makeCGImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, source, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let upright = try PhotoDecoder.uprightImage(from: data as Data)

        XCTAssertEqual(upright.width, 2)
        XCTAssertEqual(upright.height, 3)
        XCTAssertEqual(reds(try RGBAImage(cgImage: upright)), [d, a, e, b, f, c])
    }

    // MARK: - 水平ガイド

    func testUprightPortraitIsLevel() {
        let reading = LevelReading.from(gravityX: 0, y: -1, z: 0)
        XCTAssertEqual(reading.mode, .upright(roll: 0))
        XCTAssertTrue(reading.isLevel)
    }

    func testSlightTiltIsNotLevel() {
        let angle = 3 * Double.pi / 180
        let reading = LevelReading.from(gravityX: sin(angle), y: -cos(angle), z: 0)
        guard case .upright(let roll) = reading.mode else { return XCTFail("縦持ち扱いになっていない") }
        XCTAssertEqual(roll, angle, accuracy: 1e-9)
        XCTAssertFalse(reading.isLevel)
    }

    func testLandscapeIsMeasuredFromNearestQuarterTurn() {
        let reading = LevelReading.from(gravityX: -1, y: 0, z: 0)
        guard case .upright(let roll) = reading.mode else { return XCTFail("縦持ち扱いになっていない") }
        XCTAssertEqual(roll, 0, accuracy: 1e-9)
        XCTAssertTrue(reading.isLevel)
    }

    func testLookingStraightDownUsesBubble() {
        let level = LevelReading.from(gravityX: 0.01, y: -0.01, z: -0.999)
        XCTAssertEqual(level.mode, .flat(x: 0.01, y: -0.01))
        XCTAssertTrue(level.isLevel)

        let tilted = LevelReading.from(gravityX: 0.1, y: 0, z: -0.99)
        XCTAssertFalse(tilted.isLevel)
    }

    // MARK: - 撮影の向き

    func testCaptureOrientationFollowsDeviceTilt() {
        XCTAssertEqual(CaptureOrientation.from(gravityX: 0, y: -1, z: 0), .portrait)
        XCTAssertEqual(CaptureOrientation.from(gravityX: 0, y: 1, z: 0), .portraitUpsideDown)
        XCTAssertEqual(CaptureOrientation.from(gravityX: -1, y: 0, z: 0), .landscapeLeft)
        XCTAssertEqual(CaptureOrientation.from(gravityX: 1, y: 0, z: 0), .landscapeRight)
        XCTAssertEqual(CaptureOrientation.portrait.videoRotationAngle, 90)
        XCTAssertEqual(CaptureOrientation.landscapeLeft.videoRotationAngle, 0)
    }

    /// 机の作品を真上から撮るときは、少し傾いていても縦写真になる。
    func testLookingStraightDownIsPortrait() {
        XCTAssertEqual(CaptureOrientation.from(gravityX: 0.3, y: 0.05, z: -0.95), .portrait)
        XCTAssertEqual(CaptureOrientation.from(gravityX: -0.2, y: -0.3, z: -0.93), .portrait)
        XCTAssertTrue(CaptureOrientation.from(gravityX: 0, y: 0, z: -1).isPortrait)
    }
}
