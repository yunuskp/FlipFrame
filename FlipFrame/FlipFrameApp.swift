import SwiftUI
import RevenueCat

@main
struct FlipFrameApp: App {
    init() {
        Purchases.logLevel = .debug
        Purchases.configure(withAPIKey: "appl_rBQCduPFSmjaoQvomRGuKAydSmX")
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
