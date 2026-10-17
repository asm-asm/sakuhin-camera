import StoreKit
import SwiftUI

/// 購入画面に並べるプラン（表示用）。ストアの商品から作る。スクリーンショット用に見本も作れる。
struct PlanOption: Identifiable, Equatable {
    let id: String
    let title: String
    let price: String
    let detail: String
    let badge: String?
    let savings: String?

    static func make(from products: [Product]) -> [PlanOption] {
        let monthly = products.first { $0.id == ProductIDs.monthly }
        let yearly = products.first { $0.id == ProductIDs.yearly }
        var options: [PlanOption] = []
        if let yearly {
            var savings: String?
            if let monthly, monthly.price > 0 {
                let full = monthly.price * 12
                let ratio: Decimal = (full - yearly.price) / full * 100
                let percent = Int(NSDecimalNumber(decimal: ratio).doubleValue.rounded())
                if percent > 0 { savings = "\(percent)%おトク" }
            }
            options.append(PlanOption(id: yearly.id, title: "年額プラン", price: yearly.displayPrice + " / 年",
                                      detail: "月あたり " + (yearly.price / 12).formatted(yearly.priceFormatStyle),
                                      badge: "いちばんおトク", savings: savings))
        }
        if let monthly {
            options.append(PlanOption(id: monthly.id, title: "月額プラン", price: monthly.displayPrice + " / 月",
                                      detail: "まずは1か月から", badge: nil, savings: nil))
        }
        return options
    }

    static let demo: [PlanOption] = [
        PlanOption(id: ProductIDs.yearly, title: "年額プラン", price: "¥1,500 / 年", detail: "月あたり ¥125",
                   badge: "いちばんおトク", savings: "17%おトク"),
        PlanOption(id: ProductIDs.monthly, title: "月額プラン", price: "¥150 / 月", detail: "まずは1か月から",
                   badge: nil, savings: nil),
    ]
}

/// プレミアムの購入画面。
///
/// 明るいポップなデザインなので、ダークモードの端末でも常にライトモードの色で表示する（文字色も固定）。
/// 横に流れる背景見本は overlay の中に置き、画面全体の幅に影響させない。
struct PaywallView: View {
    @Environment(SubscriptionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?
    @State private var isPurchasing = false
    @State private var message: String?
    @State private var showsPrivacy = false
    @State private var showcase: [CGImage] = []
    @State private var crownBounce = false

    private enum Palette {
        static let pink = Color(red: 1.0, green: 0.36, blue: 0.52)
        static let orange = Color(red: 1.0, green: 0.55, blue: 0.30)
        static let peach = Color(red: 1.0, green: 0.90, blue: 0.86)
        static let cream = Color(red: 1.0, green: 0.97, blue: 0.94)
        static let mint = Color(red: 0.30, green: 0.70, blue: 0.56)
        static let ink = Color(red: 0.20, green: 0.15, blue: 0.16)
        static let subInk = Color(red: 0.47, green: 0.41, blue: 0.42)
        static let pop = LinearGradient(colors: [pink, orange], startPoint: .leading, endPoint: .trailing)
    }

    private var plans: [PlanOption] {
        LaunchOptions.paywallDemo ? PlanOption.demo : PlanOption.make(from: store.products)
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: 28) {
                header
                showcaseStrip
                benefitList
                if store.isPremium && !LaunchOptions.paywallDemo {
                    premiumActive
                } else {
                    planList
                        .id("plans")
                    purchaseButton
                }
                footer
            }
            .padding(.top, 8)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .task {
            if LaunchOptions.paywallScrollToPlans {
                try? await Task.sleep(for: .milliseconds(600))
                proxy.scrollTo("plans", anchor: .center)
            }
        }
        }
        .background(
            LinearGradient(colors: [Palette.peach, Palette.cream], startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
        )
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(.white.opacity(0.85)))
            }
            .padding(14)
            .accessibilityLabel("閉じる")
        }
        .environment(\.colorScheme, .light)
        .preferredColorScheme(.light)
        .alert("お知らせ", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
        .sheet(isPresented: $showsPrivacy) {
            PrivacyPolicyView()
        }
        .task {
            crownBounce.toggle()
            if store.products.isEmpty && !LaunchOptions.paywallDemo {
                await store.loadProducts()
            }
            if selectedID == nil {
                selectedID = plans.first?.id
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

    private var header: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Palette.pop)
                    .frame(width: 84, height: 84)
                    .shadow(color: Palette.pink.opacity(0.35), radius: 12, y: 6)
                Image(systemName: "crown.fill")
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(.white)
                    .symbolEffect(.bounce, value: crownBounce)
            }
            .padding(.top, 36)

            Text("作品カメラ PREMIUM")
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundStyle(Palette.ink)

            Text("背景で、作品がもっと映える。")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.pink)
        }
        .padding(.horizontal, 20)
    }

    // MARK: - 有料背景の見本（横に流れ続ける）

    private var showcaseStrip: some View {
        VStack(spacing: 12) {
            // 枠の大きさは Color.clear で決め、流れるカードは overlay に入れる（幅を押し広げない）
            Color.clear
                .frame(height: 168)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .leading) {
                    if !showcase.isEmpty {
                        TimelineView(.animation) { context in
                            marquee(time: context.date.timeIntervalSinceReferenceDate)
                        }
                    }
                }
                .clipped()

            Text("コーヒー・毛糸・観葉植物…\nスタイリング背景10種が使い放題")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
    }

    private func marquee(time: TimeInterval) -> some View {
        let cardWidth: CGFloat = 104
        let spacing: CGFloat = 14
        let loopWidth = CGFloat(showcase.count) * (cardWidth + spacing)
        let offset = CGFloat(time * 30).truncatingRemainder(dividingBy: max(loopWidth, 1))
        return HStack(spacing: spacing) {
            ForEach(0..<(showcase.count * 2), id: \.self) { index in
                Image(decorative: showcase[index % showcase.count], scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: cardWidth, height: 148)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white, lineWidth: 4))
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 4)
                    .rotationEffect(.degrees(index.isMultiple(of: 2) ? -3 : 3))
            }
        }
        .fixedSize()
        .offset(x: -offset)
    }

    // MARK: - 特典

    private var benefitList: some View {
        VStack(spacing: 0) {
            benefitRow(icon: "checkmark.seal.fill", color: Palette.pink,
                       title: "透かしロゴなし", detail: "そのままSNSやショップに載せられます")
            Divider().padding(.leading, 74)
            benefitRow(icon: "photo.stack.fill", color: Palette.orange,
                       title: "すべての背景が使える", detail: "スタイリング背景10種＋すべてのカラー")
            Divider().padding(.leading, 74)
            benefitRow(icon: "hand.raised.fill", color: Palette.mint,
                       title: "作品は撮ったまま", detail: "背景だけ変えて、作品はそのまま")
        }
        .background(RoundedRectangle(cornerRadius: 22).fill(.white))
        .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
        .padding(.horizontal, 20)
    }

    private func benefitRow(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(color))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.ink)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.subInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - プラン

    @ViewBuilder
    private var planList: some View {
        if plans.isEmpty {
            VStack(spacing: 10) {
                if store.isLoadingProducts {
                    ProgressView().tint(Palette.subInk)
                } else {
                    Text("プランを読み込めませんでした。\n通信環境を確認してください。")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.subInk)
                        .multilineTextAlignment(.center)
                    Button("再読み込み") {
                        Task { await store.loadProducts() }
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .tint(Palette.pink)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .padding(.horizontal, 20)
        } else {
            VStack(spacing: 14) {
                ForEach(plans) { plan in
                    planCard(plan)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func planCard(_ plan: PlanOption) -> some View {
        let isSelected = selectedID == plan.id
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                selectedID = plan.id
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24))
                    .foregroundStyle(isSelected ? Palette.pink : Palette.subInk.opacity(0.6))
                VStack(alignment: .leading, spacing: 4) {
                    Text(plan.title)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(Palette.ink)
                        .fixedSize()
                    Text(plan.detail)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.subInk)
                        .fixedSize()
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(plan.price)
                        .font(.system(size: 17, weight: .heavy, design: .rounded))
                        .foregroundStyle(Palette.ink)
                        .fixedSize()
                    if let savings = plan.savings {
                        Text(savings)
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(Palette.pink)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Palette.pink.opacity(0.12)))
                            .fixedSize()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 20).fill(.white))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(isSelected ? Palette.pink : Color.black.opacity(0.08), lineWidth: isSelected ? 3 : 1)
            )
            .overlay(alignment: .topLeading) {
                if let badge = plan.badge {
                    Text(badge)
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Palette.pop))
                        .offset(x: 18, y: -11)
                }
            }
            .shadow(color: .black.opacity(isSelected ? 0.08 : 0.03), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .padding(.top, plan.badge == nil ? 0 : 6)
    }

    private var purchaseButton: some View {
        Button {
            Task { await buy() }
        } label: {
            ZStack {
                if isPurchasing {
                    ProgressView().tint(.white)
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                        Text("プレミアムをはじめる")
                    }
                    .font(.system(size: 19, weight: .heavy, design: .rounded))
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(Capsule().fill(Palette.pop))
            .shadow(color: Palette.pink.opacity(0.4), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
        .disabled(isPurchasing || selectedProduct == nil)
        .padding(.horizontal, 20)
    }

    private var premiumActive: some View {
        HStack(spacing: 10) {
            Image(systemName: "crown.fill")
            Text("プレミアムをご利用中です。ありがとうございます！")
        }
        .font(.system(size: 16, weight: .bold, design: .rounded))
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 20).fill(Palette.pop))
        .padding(.horizontal, 20)
    }

    // MARK: - 注意書き・リンク

    private var footer: some View {
        VStack(spacing: 14) {
            Button("購入を復元") {
                Task { await restore() }
            }
            .font(.system(size: 14, weight: .semibold))
            .tint(Palette.pink)

            Text("サブスクリプションは、現在の期間が終わる24時間前までに解約しない限り自動で更新されます。料金は購入の確定時と更新時に Apple ID に請求されます。解約は「設定」アプリの Apple ID ＞ サブスクリプションから行えます。")
                .font(.system(size: 11))
                .foregroundStyle(Palette.subInk)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 24) {
                Link("利用規約", destination: AppLinks.termsOfUse)
                Button("プライバシーポリシー") { showsPrivacy = true }
            }
            .font(.system(size: 13))
            .tint(Palette.pink)
        }
        .padding(.horizontal, 28)
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
