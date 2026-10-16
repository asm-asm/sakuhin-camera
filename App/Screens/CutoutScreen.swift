import SwiftUI

@MainActor
@Observable
final class CutoutModel {
    enum Phase {
        case idle
        case detecting
        case ready
        case noSubject
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var segmentation: SubjectSegmentation?
    private(set) var selected: IndexSet = []
    private(set) var overlay: CGImage?
    private(set) var isMakingMask = false

    var canProceed: Bool {
        if case .ready = phase { return !selected.isEmpty && !isMakingMask }
        return false
    }

    var hint: String {
        switch phase {
        case .idle, .detecting:
            return "作品を探しています…"
        case .ready:
            let count = segmentation?.instances.count ?? 0
            if count <= 1 { return "作品を切り抜きました" }
            return "\(count)個の被写体が見つかりました。タップで選択・解除できます（白くかすんでいるものは使いません）"
        case .noSubject:
            return "作品が見つかりませんでした。背景と色の違う場所で撮り直してください"
        case .failed(let message):
            return "切り抜きに失敗しました（\(message)）"
        }
    }

    func detect(_ image: CGImage) async {
        guard case .idle = phase else { return }
        phase = .detecting
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try SubjectSegmenter.segment(image)
            }.value
            segmentation = result
            selected = result.instances
            refreshOverlay()
            phase = .ready
        } catch SubjectSegmenter.Error.noSubject {
            phase = .noSubject
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func toggle(atNormalized point: CGPoint) {
        guard case .ready = phase, let index = segmentation?.labels.instance(atNormalized: point) else { return }
        if selected.contains(index) {
            selected.remove(index)
        } else {
            selected.insert(index)
        }
        refreshOverlay()
    }

    func makeMask() async throws -> AlphaMask? {
        guard let segmentation, !selected.isEmpty else { return nil }
        isMakingMask = true
        defer { isMakingMask = false }
        let selected = selected
        return try await Task.detached(priority: .userInitiated) {
            try segmentation.makeMask(for: selected)
        }.value
    }

    private func refreshOverlay() {
        overlay = segmentation?.labels.overlayImage(selected: selected)
    }
}

struct CutoutScreen: View {
    let onNext: () -> Void

    @Environment(EditSession.self) private var session
    @State private var model = CutoutModel()
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            photo
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(model.hint)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: proceed) {
                if model.isMakingMask {
                    ProgressView()
                } else {
                    Text("次へ")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canProceed)
        }
        .padding()
        .navigationTitle("切り抜き")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let image = session.originalImage {
                await model.detect(image)
            }
        }
        .alert("マスクを作れませんでした", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var photo: some View {
        if let image = session.originalImage {
            GeometryReader { geometry in
                let imageSize = CGSize(width: image.width, height: image.height)
                let frame = ImageFit.rect(for: imageSize, in: geometry.size)
                ZStack {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                    if let overlay = model.overlay {
                        Image(decorative: overlay, scale: 1)
                            .resizable()
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                    }
                    if case .detecting = model.phase {
                        ProgressView()
                            .controlSize(.large)
                            .position(x: frame.midX, y: frame.midY)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .contentShape(Rectangle())
                .onTapGesture { location in
                    if let point = ImageFit.normalizedPoint(location, imageSize: imageSize, in: geometry.size) {
                        model.toggle(atNormalized: point)
                    }
                }
            }
        } else {
            ContentUnavailableView("写真がありません", systemImage: "photo")
        }
    }

    private func proceed() {
        Task {
            do {
                guard let mask = try await model.makeMask() else { return }
                session.mask = mask
                onNext()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
