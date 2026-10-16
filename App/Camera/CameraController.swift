import AVFoundation
import Observation
import UIKit

enum CameraError: Swift.Error {
    case noCamera
    case configurationFailed
    case noPhotoData
    case busy
}

/// 背面カメラでの撮影。セッションの操作は専用キューで行う。
@Observable
final class CameraController: NSObject {
    enum Status: Equatable {
        case idle
        case unauthorized
        case unavailable
        case running
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var isCapturing = false

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let photoOutput = AVCapturePhotoOutput()
    @ObservationIgnored private let queue = DispatchQueue(label: "com.sammy.sakuhincamera.camera")
    @ObservationIgnored private var device: AVCaptureDevice?
    @ObservationIgnored private var isConfigured = false
    @ObservationIgnored private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private var previewRotationObservation: NSKeyValueObservation?
    @ObservationIgnored private var subjectAreaObserver: NSObjectProtocol?
    @ObservationIgnored private var captureContinuation: CheckedContinuation<Data, Swift.Error>?

    /// 写真1枚の最大画素数。48MP は合成時のメモリが足りなくなるため 12MP 級までにする。
    static let maxPhotoPixels = 12_600_000

    deinit {
        if let subjectAreaObserver {
            NotificationCenter.default.removeObserver(subjectAreaObserver)
        }
    }

    @MainActor
    func start() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                status = .unauthorized
                return
            }
        default:
            status = .unauthorized
            return
        }

        do {
            try await performOnQueue {
                try self.configureIfNeeded()
                if !self.session.isRunning {
                    self.session.startRunning()
                }
            }
            status = .running
        } catch CameraError.noCamera {
            status = .unavailable
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    /// プレビュー層をつなぎ、端末の向きに合わせて回転させる。
    @MainActor
    func attachPreview(_ layer: AVCaptureVideoPreviewLayer) {
        layer.session = session
        guard let device else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
        layer.connection?.videoRotationAngle = coordinator.videoRotationAngleForHorizonLevelPreview
        previewRotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview,
                                                         options: [.new]) { [weak layer] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            DispatchQueue.main.async {
                layer?.connection?.videoRotationAngle = angle
            }
        }
        rotationCoordinator = coordinator
    }

    /// タップした位置（カメラ座標 0〜1）にピントと露出を合わせる。
    func focus(at devicePoint: CGPoint) {
        queue.async {
            self.setFocusAndExposure(at: devicePoint, continuous: false)
        }
    }

    @MainActor
    func capture(orientation: CaptureOrientation) async throws -> CGImage {
        guard status == .running, !isCapturing else { throw CameraError.busy }
        isCapturing = true
        defer { isCapturing = false }

        let settings: AVCapturePhotoSettings
        if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        } else {
            settings = AVCapturePhotoSettings()
        }
        settings.photoQualityPrioritization = .quality
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        settings.flashMode = .off

        if let connection = photoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(orientation.videoRotationAngle) {
            connection.videoRotationAngle = orientation.videoRotationAngle
        }

        let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Swift.Error>) in
            captureContinuation = continuation
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
        return try await Task.detached(priority: .userInitiated) {
            try PhotoDecoder.uprightImage(from: data)
        }.value
    }

    // MARK: - 専用キュー上の処理

    private func performOnQueue(_ work: @escaping () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            queue.async {
                do {
                    try work()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func configureIfNeeded() throws {
        guard !isConfigured else { return }
        guard let device = Self.bestBackCamera() else { throw CameraError.noCamera }
        let input = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        guard session.canAddInput(input), session.canAddOutput(photoOutput) else {
            throw CameraError.configurationFailed
        }
        session.addInput(input)
        session.addOutput(photoOutput)

        photoOutput.maxPhotoQualityPrioritization = .quality
        let dimensions = device.activeFormat.supportedMaxPhotoDimensions
        let allowed = dimensions.filter { Int($0.width) * Int($0.height) <= Self.maxPhotoPixels }
        if let largest = (allowed.isEmpty ? dimensions : allowed)
            .max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
            photoOutput.maxPhotoDimensions = largest
        }

        subjectAreaObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.subjectAreaDidChangeNotification, object: device, queue: nil
        ) { [weak self] _ in
            // 構図が変わったら、タップで固定したピントを中央の自動追従に戻す
            self?.queue.async {
                self?.setFocusAndExposure(at: CGPoint(x: 0.5, y: 0.5), continuous: true)
            }
        }

        self.device = device
        isConfigured = true
    }

    private func setFocusAndExposure(at point: CGPoint, continuous: Bool) {
        guard let device else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            let focusMode: AVCaptureDevice.FocusMode = continuous ? .continuousAutoFocus : .autoFocus
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(focusMode) {
                device.focusPointOfInterest = point
                device.focusMode = focusMode
            }
            let exposureMode: AVCaptureDevice.ExposureMode = continuous ? .continuousAutoExposure : .autoExpose
            if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(exposureMode) {
                device.exposurePointOfInterest = point
                device.exposureMode = exposureMode
            }
            device.isSubjectAreaChangeMonitoringEnabled = !continuous
        } catch {
            // ピント合わせに失敗しても撮影は続けられるので無視する
        }
    }

    /// 近接撮影でレンズを自動で切り替えられる複合カメラを優先する。
    private static func bestBackCamera() -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera,
        ]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back)
        for type in types {
            if let device = discovery.devices.first(where: { $0.deviceType == type }) {
                return device
            }
        }
        return nil
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Swift.Error?) {
        let continuation = captureContinuation
        captureContinuation = nil
        if let error {
            continuation?.resume(throwing: error)
        } else if let data = photo.fileDataRepresentation() {
            continuation?.resume(returning: data)
        } else {
            continuation?.resume(throwing: CameraError.noPhotoData)
        }
    }
}
