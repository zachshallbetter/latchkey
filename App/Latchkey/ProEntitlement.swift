#if LATCHKEY_APP_STORE
import Foundation
import StoreKit
import os

/// Whether this Mac has Latchkey Pro: the one resolver, read by the broker and the Settings screen. The answer is
/// `Transaction.currentEntitlements` for `productID`, accepting only transactions StoreKit reports as verified (Apple's
/// signature, checked here; cached by StoreKit, so it works offline after the first sync). Anything else, including a
/// failed lookup, means not Pro, and nothing in here throws into a caller. Compiled only into the App Store build.
@MainActor
final class ProEntitlement: ObservableObject {
    static let productID = "io.snackstud.latchkey.pro"
    static let shared = ProEntitlement()

    /// Read from any thread by the broker.
    private let flag = OSAllocatedUnfairLock(initialState: false)
    nonisolated func current() -> Bool { flag.withLock { $0 } }

    @Published private(set) var isPro = false
    @Published private(set) var purchaseDate: Date?
    @Published private(set) var product: Product?
    @Published private(set) var busy = false
    /// Why the last purchase, restore or price lookup didn't finish; nil when nothing needs saying.
    @Published private(set) var message: String?
    private var updates: Task<Void, Never>?

    private init() {}

    /// Starts listening for refunds and purchases made elsewhere, then reads the current state and the price.
    func start() {
        guard updates == nil else { return }
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = result { await transaction.finish() }
                await self.refresh()
            }
        }
        Task {
            await refresh()
            await loadProduct()
        }
    }

    func refresh() async {
        var date: Date?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.productID == Self.productID, transaction.revocationDate == nil else { continue }
            date = transaction.purchaseDate
        }
        flag.withLock { $0 = date != nil }
        isPro = date != nil
        purchaseDate = date
    }

    func loadProduct() async {
        do {
            product = try await Product.products(for: [Self.productID]).first
            message = product == nil ? "Latchkey Pro isn't available from the App Store right now." : nil
        } catch {
            product = nil
            message = "The App Store price couldn't be loaded: \(error.localizedDescription)"
        }
    }

    func buy() async {
        guard let product else { return }
        busy = true
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                if case .verified(let transaction) = result {
                    await transaction.finish()
                    message = nil
                } else {
                    message = "The App Store couldn't verify this purchase."
                }
            case .pending: message = "The purchase is waiting for approval."
            case .userCancelled: message = nil
            @unknown default: message = "The purchase didn't complete."
            }
        } catch {
            message = "The purchase didn't complete: \(error.localizedDescription)"
        }
        await refresh()
    }

    func restore() async {
        busy = true
        defer { busy = false }
        do {
            try await AppStore.sync()
            message = nil
        } catch {
            message = "Purchases couldn't be restored: \(error.localizedDescription)"
        }
        await refresh()
    }
}
#endif
