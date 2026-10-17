import StoreKit
import SwiftUI

/// プレミアムの購入画面。有料背景の実物を流して見せ、年額プランをおすすめする。
struct PaywallView: View {
    @Environment(SubscriptionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: Product.ID?
    @State private var isPurchasing = false
    @State private var message: String?
    @State private var showsPrivacy = false
    @State private var showcase: [CGImage] = []
    @State private var appeared = false
    @State private var pulse = false

    static let pink = Color(red: 1.0, green: 0.42, blue: 0.58)
    static let orange = Color(red: 1.0, green: 0.62, blue: 0.40)
    static let yellow = Color(red: 1.0, green: 0.80, blue: 0.38)
    static let cream = Color(red: 1.0, green: 0.97, blue: 0.94)
    static let popGradient = LinearGradient(colors: [pink, orange, yellow],
                                            startPoint: .topLeading, endPoint: .bottomTrailing)

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                VStack(spacing: 24) {
                    hero
                    showcaseStrip
                    benefits
                    if store.isPremium {
                        activeBadge
                    } else {
                        plans
                        purchaseButton
                    }
                    footer
                }
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .background(Self.cream.ignoresSafeArea())
            .ignoresSafeArea(edges: .top)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(.black.opacity(0.25)))
            }
            .padding(16)
            .accessibilityLabel("閉じる")
        }
        // 白いカードの明るいデザインなので、ダークモードの端末でも文字色はライトモードにする
        .environment(\.colorScheme, .light)
        .alert("お知らせ", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
        .sheet(isPresented: $showsPrivacy) {
            PrivacyPolicyView()
        }
        .task {
            appeared = true
            pulse = true
            if store.products.isEmpty {
                await store.loadProducts()
            }
            if selectedID == nil {
                selectedID = yearly?.id ?? store.products.first?.id
            }
        }
        .task {
            let library = BackgroundLibrary.shared
            let items = library.items.filter { item in
                if case .image = item.kind { return item.premium } else { return false }
            }
            showcase = await Task.detached(priority: .userInitiated) {
                items.compactMap { BackgroundThumbnail.make(item: $0, library: library, original: nil, maxPixelSize: 320) }
            }.value
        }
    }

    // MARK: - ヘッダー

    private var hero: some View {
        ZStack {
            Self.popGradient
            sparkle(size: 18, x: -130, y: -40)
            sparkle(size: 12, x: 120, y: -55)
            sparkle(size: 22, x: 140, y: 30)
            sparkle(size: 10, x: -110, y: 45)
            VStack(spacing: 10) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                    .symbolEffect(.bounce, value: appeared)
                Text("作品カメラ PREMIUM")
                    .font(.system(.title2, design: .rounded).weight(.heavy))
                    .foregroundStyle(.white)
                Text("背景で、作品がもっと映える。")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.white.opacity(0.95))
            }
            .padding(.top, 40)
        }
        .frame(height: 240)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 36, bottomTrailingRadius: 36))
    }

    private func sparkle(size: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        Image(systemName: "sparkle")
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(.white.opacity(0.8))
            .offset(x: x, y: y + 20)
            .symbolEffect(.pulse, options: .repeating)
    }

    // MARK: - 有料背景の見本（流れ続ける）

    private var showcaseStrip: some View {
        VStack(spacing: 10) {
            if showcase.isEmpty {
                Color.clear.frame(height: 160)
            } else {
                TimelineView(.animation) { context in
                    marquee(time: context.date.timeIntervalSinceReferenceDate)
                }
                .frame(height: 160)
                .clipped()
            }
            Text("コーヒー・毛糸・観葉植物… スタイリング背景が使い放題")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(Self.pink)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    private func marquee(time: TimeInterval) -> some View {
        let cardWidth: CGFloat = 100
        let spacing: CGFloat = 14
        let setWidth = CGFloat(showcase.count) * (cardWidth + spacing)
        let offset = CGFloat(time * 28).truncatingRemainder(dividingBy: max(setWidth, 1))
        let cards = Array((showcase + showcase).enumerated())
        return HStack(spacing: spacing) {
            ForEach(cards, id: \.offset) { index, image in
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: cardWidth, height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white, lineWidth: 3))
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 4)
                    .rotationEffect(.degrees(index.isMultiple(of: 2) ? -4 : 4))
            }
        }
        .offset(x: -offset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    // MARK: - 特典

    private var benefits: some View {
        VStack(spacing: 12) {
            benefitRow(icon: "checkmark.seal.fill", color: Self.pink,
                       title: "透かしロゴなし", detail: "そのままSNSやショップに載せられる")
            benefitRow(icon: "photo.stack.fill", color: Self.orange,
                       title: "全部の背景が使える", detail: "スタイリング背景10種＋すべてのカラー")
            benefitRow(icon: "hand.raised.fill", color: Color(red: 0.35, green: 0.7, blue: 0.55),
                       title: "作品は撮ったまま", detail: "変えるのは背景だけ。作品の画素は一切いじりません")
        }
        .padding(.horizontal)
    }

    private func benefitRow(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(color.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.headline, design: .rounded))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18).fill(.white))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
    }

    // MARK: - プラン

    private var monthly: Product? { store.products.first { $0.id == ProductIDs.monthly } }
    private var yearly: Product? { store.products.first { $0.id == ProductIDs.yearly } }

    /// 年額が月額12か月分よりどれだけ安いか（%）。
    private var yearlySavingsPercent: Int? {
        guard let monthly, let yearly, monthly.price > 0 else { return nil }
        let full = monthly.price * 12
        let ratio: Decimal = (full - yearly.price) / full * 100
        let percent = NSDecimalNumber(decimal: ratio).intValue
        return percent > 0 ? percent : nil
    }

    @ViewBuilder
    private var plans: some View {
        if store.products.isEmpty {
            VStack(spacing: 10) {
                if store.isLoadingProducts {
                    ProgressView()
                } else {
                    Text("プランを読み込めませんでした。通信環境を確認してください。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("再読み込み") {
                        Task { await store.loadProducts() }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        } else {
            VStack(spacing: 12) {
                if let yearly {
                    planCard(yearly, title: "年額プラン", badge: "いちばんおトク",
                             detail: "月あたり " + (yearly.price / 12).formatted(yearly.priceFormatStyle),
                             savings: yearlySavingsPercent.map { "\($0)%おトク" })
                }
                if let monthly {
                    planCard(monthly, title: "月額プラン", badge: nil, detail: "まずは1か月から", savings: nil)
                }
            }
            .padding(.horizontal)
        }
    }

    private func planCard(_ product: Product, title: String, badge: String?, detail: String,
                          savings: String?) -> some View {
        let isSelected = selectedID == product.id
        let period = product.id == ProductIDs.yearly ? " / 年" : " / 月"
        let border: AnyShapeStyle = isSelected ? AnyShapeStyle(Self.popGradient) : AnyShapeStyle(Color.black.opacity(0.08))
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                selectedID = product.id
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? Self.pink : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(.headline, design: .rounded))
                        if let savings {
                            Text(savings)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Self.pink)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Self.pink.opacity(0.12)))
                        }
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(product.displayPrice + period)
                    .font(.system(.headline, design: .rounded).weight(.bold))
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 20).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(border, lineWidth: isSelected ? 3 : 1))
            .overlay(alignment: .topLeading) {
                if let badge {
                    Text(badge)
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Self.popGradient))
                        .offset(x: 16, y: -12)
                }
            }
            .scaleEffect(isSelected ? 1.0 : 0.97)
        }
        .buttonStyle(.plain)
        .padding(.top, badge == nil ? 0 : 8)
    }

    private var purchaseButton: some View {
        Button {
            Task { await buy() }
        } label: {
            ZStack {
                if isPurchasing {
                    ProgressView().tint(.white)
                } else {
                    Label("プレミアムをはじめる", systemImage: "sparkles")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(Capsule().fill(Self.popGradient))
            .shadow(color: Self.pink.opacity(0.45), radius: 12, y: 6)
            .scaleEffect(pulse && !isPurchasing ? 1.03 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        }
        .buttonStyle(.plain)
        .disabled(isPurchasing || selectedProduct == nil)
        .opacity(selectedProduct == nil ? 0.5 : 1)
        .padding(.horizontal)
    }

    private var activeBadge: some View {
        Label("プレミアムをご利用中です。ありがとうございます！", systemImage: "crown.fill")
            .font(.system(.headline, design: .rounded))
            .foregroundStyle(.white)
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 20).fill(Self.popGradient))
            .padding(.horizontal)
    }

    // MARK: - 注意書き・リンク

    private var footer: some View {
        VStack(spacing: 12) {
            Button("購入を復元") {
                Task { await restore() }
            }
            .font(.footnote.weight(.semibold))

            Text("サブスクリプションは、現在の期間が終わる24時間前までに解約しない限り自動で更新されます。料金は購入の確定時と更新時に Apple ID に請求されます。解約は「設定」アプリの Apple ID ＞ サブスクリプションから行えます。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 20) {
                Link("利用規約", destination: AppLinks.termsOfUse)
                Button("プライバシーポリシー") { showsPrivacy = true }
            }
            .font(.caption)
        }
        .padding(.horizontal, 24)
    }

    // MARK: - 購入

    private var selectedProduct: Product? {
        store.products.first { $0.id == selectedID }
    }

    private func buy() async {
        guard let product = selectedProduct else { return }
        isPurchasing = true
        defer { isPurchasing = false }
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
