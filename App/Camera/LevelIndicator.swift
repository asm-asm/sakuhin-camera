import CoreMotion
import Foundation
import Observation
import SwiftUI

/// 端末の傾き（重力の向き）から水平ガイドの表示内容を決める。
struct LevelReading: Equatable {
    enum Mode: Equatable {
        /// 立てて撮るとき。roll は最寄りの縦・横向きからの傾き（ラジアン、時計回りが正）。
        case upright(roll: Double)
        /// 真上から撮るとき（机に置いた作品を見下ろす）。x, y は重力の傾き成分。
        case flat(x: Double, y: Double)
    }

    let mode: Mode
    let isLevel: Bool

    static let uprightTolerance = 1.0 * Double.pi / 180
    static let flatTolerance = sin(2.0 * Double.pi / 180)

    static func from(gravityX x: Double, y: Double, z: Double) -> LevelReading {
        if abs(z) > 0.85 {
            let tilt = (x * x + y * y).squareRoot()
            return LevelReading(mode: .flat(x: x, y: y), isLevel: tilt < flatTolerance)
        }
        let angle = atan2(x, -y)
        let quarter = Double.pi / 2
        let roll = angle - (angle / quarter).rounded() * quarter
        return LevelReading(mode: .upright(roll: roll), isLevel: abs(roll) < uprightTolerance)
    }
}

/// 撮影する写真の向き。端末の傾きから決める。
enum CaptureOrientation: Equatable {
    case portrait
    case portraitUpsideDown
    case landscapeLeft
    case landscapeRight

    /// 机の作品を真上から撮るとき（端末が水平）は縦向きとみなす。
    /// iOS の自動判定はこの姿勢で縦横を決められず、横向きの写真になることがあるため。
    static func from(gravityX x: Double, y: Double, z: Double) -> CaptureOrientation {
        if abs(z) > 0.85 { return .portrait }
        if abs(x) > abs(y) {
            return x < 0 ? .landscapeLeft : .landscapeRight
        }
        return y <= 0 ? .portrait : .portraitUpsideDown
    }

    /// 背面カメラの写真接続に設定する回転角（度）。
    var videoRotationAngle: CGFloat {
        switch self {
        case .portrait: return 90
        case .portraitUpsideDown: return 270
        case .landscapeLeft: return 0
        case .landscapeRight: return 180
        }
    }

    var isPortrait: Bool { self == .portrait || self == .portraitUpsideDown }
}

@Observable
final class MotionLevel {
    private(set) var reading: LevelReading?
    private(set) var orientation: CaptureOrientation = .portrait
    @ObservationIgnored private let manager = CMMotionManager()

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let gravity = motion?.gravity else { return }
            self?.reading = .from(gravityX: gravity.x, y: gravity.y, z: gravity.z)
            let orientation = CaptureOrientation.from(gravityX: gravity.x, y: gravity.y, z: gravity.z)
            if self?.orientation != orientation {
                self?.orientation = orientation
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}

/// 中央の水平ガイド。立てているときは水平線、真上から撮るときは気泡で表示する。
struct LevelView: View {
    let reading: LevelReading

    var body: some View {
        let color: Color = reading.isLevel ? .yellow : .white
        switch reading.mode {
        case .upright(let roll):
            ZStack {
                HStack(spacing: 140) {
                    Rectangle().frame(width: 24, height: 1)
                    Rectangle().frame(width: 24, height: 1)
                }
                .foregroundStyle(.white.opacity(0.6))
                Rectangle()
                    .fill(color)
                    .frame(width: 120, height: 2)
                    .rotationEffect(.radians(-roll))
            }
            .animation(.linear(duration: 0.1), value: roll)
        case .flat(let x, let y):
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.7), lineWidth: 1.5)
                    .frame(width: 44, height: 44)
                Circle()
                    .fill(color)
                    .frame(width: 14, height: 14)
                    .offset(x: clamp(-x * 300), y: clamp(y * 300))
            }
            .animation(.linear(duration: 0.1), value: x)
        }
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, -60), 60)
    }
}
