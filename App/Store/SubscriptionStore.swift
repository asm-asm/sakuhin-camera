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

    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    func start() async {
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
        } catch {
            loadFailed = true
        }
    }

    /// 購入できたら true。キャンセル・保留は false。
    func purchase(_ product: Product) async throws -> Bool {
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            guard case .verified(let transaction) = verification else { return false }
            await transaction.finish()
            await refreshEntitlements()
            return true
        case .pending, .userCancelled:
            return false
        @unknown default:
            return false
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
