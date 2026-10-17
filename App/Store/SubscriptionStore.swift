import Foundation
import Observation
import StoreKit

/// StoreKit 2 のサブスク。有料版なら透かしなし・全背景。
@MainActor
@Observable
final class SubscriptionStore {
    private(set) var products: [Product] = []
    private(set) var isPremium = false
    private(set) var isLoadingProducts = false
    private(set) var loadFailed = false
    /// 読み込みに失敗した理由（画面に出して原因を調べられるようにする）。
    private(set) var loadErrorDescription: String?

    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    func start() async {
        if DemoContent.isPremium {
            // スクリーンショット撮影モード：プレミアムの見た目で撮る
            isPremium = true
            return
        }
        if updatesTask == nil {
            updatesTask = Task { [weak self] in
                for await update in Transaction.updates {
                    if case .verified(let transaction) = update {
                        await transaction.finish()
                    }
                    await self?.refreshEntitlements()
                }
            }
        }
        await refreshEntitlements()
        await loadProducts()
    }

    func loadProducts() async {
        guard !isLoadingProducts else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            products = try await Product.products(for: ProductIDs.all).sorted { $0.price < $1.price }
            loadFailed = products.isEmpty
            loadErrorDescription = products.isEmpty ? "ストアから商品が返ってきませんでした（0件）" : nil
        } catch {
            loadFailed = true
            loadErrorDescription = error.localizedDescription
        }
    }

    enum PurchaseOutcome: Equatable {
        case purchased
        case cancelled
        case pending
        case unverified
    }

    /// 購入の結果を処理する。購入自体は画面側の `@Environment(\.purchase)` で行う
    /// （画面に結びつけないと、購入の確認画面が出ずにキャンセル扱いになることがあるため）。
    func handle(_ result: Product.PurchaseResult) async -> PurchaseOutcome {
        switch result {
        case .success(let verification):
            guard case .verified(let transaction) = verification else { return .unverified }
            await transaction.finish()
            await refreshEntitlements()
            return .purchased
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .cancelled
        }
    }

    func restore() async throws {
        try await AppStore.sync()
        await refreshEntitlements()
    }

    func refreshEntitlements() async {
        var premium = false
        for await entitlement in Transaction.currentEntitlements {
            if case .verified(let transaction) = entitlement,
               ProductIDs.all.contains(transaction.productID),
               transaction.revocationDate == nil {
                premium = true
            }
        }
        isPremium = premium
    }
}
