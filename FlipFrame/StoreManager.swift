import RevenueCat
import SwiftUI

@MainActor
final class StoreManager: NSObject, ObservableObject {
    static let shared = StoreManager()
    
    @Published var products: [StoreProduct] = []
    @Published var isPurchased = UserDefaults.standard.bool(forKey: "removesWatermark") {
        didSet {
            UserDefaults.standard.set(isPurchased, forKey: "removesWatermark")
        }
    }
    @Published var isPurchasing = false
    @Published var purchaseError: String?
    
    private let productIDs = ["com.flipframe.removewatermark"]
    
    override init() {
        super.init()
        
        // Ensure RevenueCat is configured before accessing Purchases.shared
        if !Purchases.isConfigured {
            Purchases.logLevel = .debug
            Purchases.configure(withAPIKey: "appl_rBQCduPFSmjaoQvomRGuKAydSmX")
        }
        
        Purchases.shared.delegate = self
        
        Task {
            await fetchProducts()
            await updatePurchaseStatus()
        }
    }
    
    func fetchProducts() async {
        do {
            products = try await Purchases.shared.products(productIDs)
        } catch {
            print("Failed to fetch products: \(error)")
        }
    }
    
    func purchase() async -> Bool {
        if products.isEmpty {
            await fetchProducts()
        }
        
        guard let product = products.first else {
            purchaseError = "Product not found in App Store."
            return false
        }
        
        isPurchasing = true
        purchaseError = nil
        
        do {
            let purchaseResult = try await Purchases.shared.purchase(product: product)
            let isPremium = purchaseResult.customerInfo.entitlements["premium"]?.isActive == true ||
                            purchaseResult.customerInfo.allPurchasedProductIdentifiers.contains("com.flipframe.removewatermark")
            isPurchased = isPremium
            isPurchasing = false
            return isPremium
        } catch {
            if let rcError = error as? ErrorCode {
                if rcError == .purchaseCancelledError {
                    purchaseError = "Purchase cancelled."
                } else {
                    purchaseError = error.localizedDescription
                }
            } else {
                purchaseError = error.localizedDescription
            }
        }
        
        isPurchasing = false
        return false
    }
    
    func restore() async -> Bool {
        isPurchasing = true
        purchaseError = nil
        
        do {
            let customerInfo = try await Purchases.shared.restorePurchases()
            let isPremium = customerInfo.entitlements["premium"]?.isActive == true ||
                            customerInfo.allPurchasedProductIdentifiers.contains("com.flipframe.removewatermark")
            isPurchased = isPremium
            isPurchasing = false
            return isPremium
        } catch {
            purchaseError = error.localizedDescription
            isPurchasing = false
            return false
        }
    }
    
    func updatePurchaseStatus() async {
        do {
            let customerInfo = try await Purchases.shared.customerInfo()
            let isPremium = customerInfo.entitlements["premium"]?.isActive == true ||
                            customerInfo.allPurchasedProductIdentifiers.contains("com.flipframe.removewatermark")
            isPurchased = isPremium
        } catch {
            print("Failed to fetch customer info: \(error)")
        }
    }
}

extension StoreManager: PurchasesDelegate {
    nonisolated func purchases(_ purchases: Purchases, receivedUpdated customerInfo: CustomerInfo) {
        Task { @MainActor in
            let isPremium = customerInfo.entitlements["premium"]?.isActive == true ||
                            customerInfo.allPurchasedProductIdentifiers.contains("com.flipframe.removewatermark")
            StoreManager.shared.isPurchased = isPremium
        }
    }
}
