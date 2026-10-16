import StoreKit
import SwiftUI

/// プレミアムの購入画面。
struct PaywallView: View {
    @Environment(SubscriptionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var purchasing: Product.ID?
    @State private var message: String?
    @State private var showsPrivacy = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("書き出し画像の透かし（ロゴ）なし", systemImage: "checkmark.seal.fill")
                        Label("すべての背景が使える", systemImage: "photo.stack.fill")
                        Label("作品は撮ったまま。背景だけを差し替え", systemImage: "hand.raised.fill")
                    }
                    .font(.body)

                    if store.isPremium {
                        Label("プレミアムをご利用中です", systemImage: "crown.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)
                    } else {
                        plans
                    }

                    Button("購入を復元") {
                        Task { await restore() }
                    }

                    Text("サブスクリプションは、現在の期間が終わる24時間前までに解約しない限り自動で更新されます。料金は購入の確定時と更新時に Apple ID に請求されます。解約は「設定」アプリの Apple ID ＞ サブスクリプションから行えます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 20) {
                        Link("利用規約", destination: AppLinks.termsOfUse)
                        Button("プライバシーポリシー") { showsPrivacy = true }
                    }
                    .font(.footnote)
                }
                .padding()
            }
            .navigationTitle("プレミアム")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .alert("お知らせ", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
            .sheet(isPresented: $showsPrivacy) {
                PrivacyPolicyView()
            }
            .task {
                if store.products.isEmpty {
                    await store.loadProducts()
                }
            }
        }
    }

    @ViewBuilder
    private var plans: some View {
        if store.products.isEmpty {
            if store.isLoadingProducts {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("プランを読み込めませんでした。通信環境を確認してください。")
                        .foregroundStyle(.secondary)
                    Button("再読み込み") {
                        Task { await store.loadProducts() }
                    }
                }
            }
        } else {
            VStack(spacing: 12) {
                ForEach(store.products) { product in
                    Button {
                        Task { await buy(product) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(product.displayName.isEmpty ? planName(product) : product.displayName)
                                    .font(.headline)
                                Text(periodText(product))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if purchasing == product.id {
                                ProgressView()
                            } else {
                                Text(product.displayPrice)
                                    .font(.headline)
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .disabled(purchasing != nil)
                }
            }
        }
    }

    private func planName(_ product: Product) -> String {
        product.id == ProductIDs.yearly ? "年額プラン" : "月額プラン"
    }

    private func periodText(_ product: Product) -> String {
        guard let period = product.subscription?.subscriptionPeriod else { return "" }
        switch period.unit {
        case .year: return "\(product.displayPrice) / 年（自動更新）"
        case .month: return "\(product.displayPrice) / 月（自動更新）"
        case .week: return "\(product.displayPrice) / 週（自動更新）"
        case .day: return "\(product.displayPrice) / 日（自動更新）"
        @unknown default: return product.displayPrice
        }
    }

    private func buy(_ product: Product) async {
        purchasing = product.id
        defer { purchasing = nil }
        do {
            if try await store.purchase(product) {
                dismiss()
            }
        } catch {
            message = "購入できませんでした（\(error.localizedDescription)）"
        }
    }

    private func restore() async {
        do {
            try await store.restore()
            message = store.isPremium ? "購入を復元しました" : "復元できる購入が見つかりませんでした"
        } catch {
            message = "復元できませんでした（\(error.localizedDescription)）"
        }
    }
}

/// 設定（プレミアム・復元・規約）。
struct SettingsView: View {
    @Environment(SubscriptionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var showsPaywall = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if store.isPremium {
                        Label("プレミアムをご利用中です", systemImage: "crown.fill")
                    } else {
                        Button {
                            showsPaywall = true
                        } label: {
                            Label("プレミアムにする（透かしなし・全背景）", systemImage: "crown")
                        }
                    }
                    Button("購入を復元") {
                        Task {
                            do {
                                try await store.restore()
                                message = store.isPremium ? "購入を復元しました" : "復元できる購入が見つかりませんでした"
                            } catch {
                                message = "復元できませんでした（\(error.localizedDescription)）"
                            }
                        }
                    }
                }
                Section {
                    Link("利用規約", destination: AppLinks.termsOfUse)
                    NavigationLink("プライバシーポリシー") {
                        PrivacyPolicyContent()
                    }
                }
                Section {
                    LabeledContent("バージョン", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .sheet(isPresented: $showsPaywall) {
                PaywallView()
            }
            .alert("お知らせ", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
        }
    }
}

struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PrivacyPolicyContent()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("閉じる") { dismiss() }
                    }
                }
        }
    }
}

struct PrivacyPolicyContent: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("このアプリは、撮影した写真をすべて端末の中だけで処理します。写真や個人情報を外部のサーバーへ送信・保存することはありません。")
                Text("カメラ").font(.headline)
                Text("作品を撮影するためにカメラを使用します。撮影した写真は、加工のために端末内で一時的に使うだけです。")
                Text("写真ライブラリ").font(.headline)
                Text("加工した写真を保存するために、写真ライブラリへの追加のみを行います。ライブラリ内の写真を読み取ることはありません。")
                Text("購入").font(.headline)
                Text("サブスクリプションの購入は Apple の App Store を通じて行われ、支払い情報をこのアプリが受け取ることはありません。")
                Text("解析・広告").font(.headline)
                Text("利用状況の解析や広告のための情報収集は行いません。")
            }
            .padding()
        }
        .navigationTitle("プライバシーポリシー")
        .navigationBarTitleDisplayMode(.inline)
    }
}
