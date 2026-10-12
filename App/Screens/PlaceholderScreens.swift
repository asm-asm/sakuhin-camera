import SwiftUI

// 画面遷移の骨組み。各画面は実装の段階ごとに別ファイルへ置き換える。

struct CameraScreen: View {
    let onNext: () -> Void

    var body: some View {
        StepPlaceholder(title: "撮影", message: "カメラ画面（段階4で実装）", nextLabel: "次へ", onNext: onNext)
    }
}

struct CutoutScreen: View {
    let onNext: () -> Void

    var body: some View {
        StepPlaceholder(title: "切り抜き", message: "切り抜き画面（段階3で実装）", nextLabel: "次へ", onNext: onNext)
    }
}

struct BackgroundScreen: View {
    let onNext: () -> Void

    var body: some View {
        StepPlaceholder(title: "背景", message: "背景画面（段階5で実装）", nextLabel: "次へ", onNext: onNext)
    }
}

struct ExportScreen: View {
    let onFinish: () -> Void

    var body: some View {
        StepPlaceholder(title: "書き出し", message: "書き出し画面（段階7で実装）", nextLabel: "最初に戻る", onNext: onFinish)
    }
}

private struct StepPlaceholder: View {
    let title: String
    let message: String
    let nextLabel: String
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text(message)
                .foregroundStyle(.secondary)
            Button(nextLabel, action: onNext)
                .buttonStyle(.borderedProminent)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
