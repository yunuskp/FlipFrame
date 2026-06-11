import SwiftUI
import RevenueCat


struct PremiumPaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var storeManager = StoreManager.shared
    @ObservedObject var viewModel: ContentViewModel
    
    var body: some View {
        GeometryReader { proxy in
            let scale = min(max(proxy.size.height / 852, 0.78), 1.0)
            let bottomInset = proxy.safeAreaInsets.bottom
            let price = storeManager.products.first?.localizedPriceString ?? "$4.99"
            
            ZStack {
                // Deep premium dark background
                Color(red: 0.03, green: 0.03, blue: 0.08)
                    .ignoresSafeArea()
                
                // Neon glow in background
                RadialGradient(
                    colors: [Color(red: 0.86, green: 0.1, blue: 0.98).opacity(0.18), .clear],
                    center: .topLeading,
                    startRadius: 20,
                    endRadius: 400
                )
                .ignoresSafeArea()
                
                RadialGradient(
                    colors: [Color(red: 0.05, green: 0.55, blue: 1.0).opacity(0.15), .clear],
                    center: .bottomTrailing,
                    startRadius: 20,
                    endRadius: 450
                )
                .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Header Bar
                    HStack {
                        Spacer()
                        
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14 * scale, weight: .bold))
                                .foregroundStyle(.white.opacity(0.65))
                                .frame(width: 32 * scale, height: 32 * scale)
                                .background(.white.opacity(0.08), in: Circle())
                                .overlay {
                                    Circle()
                                        .stroke(.white.opacity(0.12), lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16 * scale)
                    
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 24 * scale) {
                            
                            // Pro Badge & Title
                            VStack(spacing: 8 * scale) {
                                Text("Remove Watermark")
                                    .font(.system(size: 28 * scale, weight: .black, design: .rounded))
                                    .foregroundStyle(.white)
                                
                                Text("Convert portrait/landscape videos cleanly without branding.")
                                    .font(.system(size: 14 * scale, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.65))
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 24)
                            }
                            
                            // Animated Demonstration View showing re-framing and watermark removal
                            AnimatedDemoView(scale: scale)
                                .padding(.horizontal, 20)
                            
                            // Features List
                            VStack(alignment: .leading, spacing: 18 * scale) {
                                featureRow(
                                    icon: "checkmark.seal.fill",
                                    iconColor: Color(red: 1.0, green: 0.20, blue: 0.85),
                                    title: "No Watermark",
                                    subtitle: "Export clean, professional videos without FlipFrame branding."
                                )
                                
                                featureRow(
                                    icon: "arrow.left.and.right.righttriangle.left.and.righttriangle.right.fill",
                                    iconColor: Color(red: 0.12, green: 0.65, blue: 1.0),
                                    title: "Unlimited Re-framing",
                                    subtitle: "Convert landscape-to-portrait or portrait-to-landscape seamlessly."
                                )
                                
                                featureRow(
                                    icon: "infinity",
                                    iconColor: .green,
                                    title: "Lifetime Ownership",
                                    subtitle: LocalizedStringKey("Pay \(price) once and keep all features forever. No subscriptions.")
                                )
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 20 * scale)
                            .background(
                                RoundedRectangle(cornerRadius: 24 * scale, style: .continuous)
                                    .fill(Color(red: 0.06, green: 0.06, blue: 0.14).opacity(0.6))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 24 * scale, style: .continuous)
                                            .stroke(Color.white.opacity(0.08), lineWidth: 1.5)
                                    }
                            )
                            .padding(.horizontal, 20)
                            
                        }
                    }
                    
                    // Purchase Actions Area
                    VStack(spacing: 16 * scale) {
                        // Error message display if any
                        if let error = storeManager.purchaseError {
                            Text(error)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }
                        
                        // Buy button
                        Button {
                            Task {
                                let success = await storeManager.purchase()
                                if success {
                                    viewModel.removesWatermark = true
                                    dismiss()
                                }
                            }
                        } label: {
                            HStack {
                                if storeManager.isPurchasing {
                                    ProgressView()
                                        .tint(.white)
                                        .padding(.trailing, 8)
                                }
                                
                                if let displayPrice = storeManager.products.first?.localizedPriceString {
                                    Text(LocalizedStringKey("Remove Watermark for \(displayPrice)"))
                                        .font(.system(size: 17 * scale, weight: .bold, design: .rounded))
                                } else {
                                    Text("Remove Watermark - $4.99")
                                        .font(.system(size: 17 * scale, weight: .bold, design: .rounded))
                                }
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16 * scale)
                            .background(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.12, green: 0.65, blue: 1.0),
                                        Color(red: 0.46, green: 0.22, blue: 1.0),
                                        Color(red: 1.0, green: 0.20, blue: 0.85)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .clipShape(Capsule())
                            .overlay {
                                Capsule()
                                    .stroke(
                                        LinearGradient(
                                            colors: [.white.opacity(0.35), .clear],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        ),
                                        lineWidth: 1
                                    )
                            }
                            .shadow(color: .purple.opacity(0.35), radius: 12, y: 5)
                        }
                        .buttonStyle(.plain)
                        .disabled(storeManager.isPurchasing)
                        .padding(.horizontal, 24)
                        
                        // Auxiliary buttons (Restore, Terms, Privacy)
                        HStack(spacing: 24 * scale) {
                            Button("Restore Purchase") {
                                Task {
                                    let success = await storeManager.restore()
                                    if success {
                                        viewModel.removesWatermark = true
                                        dismiss()
                                    }
                                }
                            }
                            .font(.system(size: 13 * scale, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.55))
                            
                            Text("•")
                                .font(.system(size: 13 * scale))
                                .foregroundStyle(.white.opacity(0.24))
                            
                            Link("Terms of Use", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                                .font(.system(size: 13 * scale, weight: .bold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.55))
                            
                            Text("•")
                                .font(.system(size: 13 * scale))
                                .foregroundStyle(.white.opacity(0.24))
                            
                            Link("Privacy Policy", destination: URL(string: "https://flipframe.app/privacy")!)
                                .font(.system(size: 13 * scale, weight: .bold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        .padding(.bottom, max(16, bottomInset))
                    }
                    .padding(.top, 16 * scale)
                    .background(Color(red: 0.04, green: 0.04, blue: 0.10).opacity(0.95))
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(Color.white.opacity(0.06))
                            .frame(height: 1)
                    }
                }
            }
        }
    }
    
    private func featureRow(icon: String, iconColor: Color, title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(iconColor)
                .frame(width: 24, height: 24)
                .padding(6)
                .background(iconColor.opacity(0.12), in: Circle())
            
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                
                Text(subtitle)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.52))
                    .lineLimit(2)
            }
        }
    }
}

struct AnimatedDemoView: View {
    let scale: CGFloat
    @State private var isLandscape = false
    @State private var showWatermark = true
    
    let timer = Timer.publish(every: 3.0, on: .main, in: .common).autoconnect()
    
    var body: some View {
        VStack(spacing: 12 * scale) {
            ZStack {
                // Background dark preview area
                RoundedRectangle(cornerRadius: 16 * scale, style: .continuous)
                    .fill(Color.black.opacity(0.45))
                    .frame(height: 190 * scale)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16 * scale, style: .continuous)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1.5)
                    }
                
                // Animated Frame Container
                ZStack(alignment: .bottomTrailing) {
                    // Simulated video background image
                    Image("export_video")
                        .resizable()
                        .scaledToFill()
                        .frame(
                            width: isLandscape ? 220 * scale : 124 * scale,
                            height: isLandscape ? 124 * scale : 160 * scale
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8 * scale))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8 * scale)
                                .stroke(
                                    LinearGradient(
                                        colors: [Color.blue.opacity(0.4), Color.pink.opacity(0.4)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1.5
                                )
                        }
                        .shadow(color: .purple.opacity(0.25), radius: 8)
                        .animation(.spring(response: 0.6, dampingFraction: 0.75), value: isLandscape)
                    
                    // Watermark overlay
                    HStack(spacing: 4 * scale) {
                        Image(systemName: "video.fill")
                            .font(.system(size: 8 * scale))
                        Text("FlipFrame")
                            .font(.system(size: 8 * scale, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6 * scale)
                    .padding(.vertical, 3 * scale)
                    .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                    .overlay {
                        // Red strike-through line when Pro is active (watermark removed)
                        if !showWatermark {
                            Rectangle()
                                .fill(Color.red)
                                .frame(height: 2 * scale)
                        }
                    }
                    .padding(8 * scale)
                    .opacity(showWatermark ? 1.0 : 0.25)
                    .animation(.easeInOut(duration: 0.4), value: showWatermark)
                }
                
                // Sparkles popping up when watermark disappears
                if !showWatermark {
                    Image(systemName: "sparkles")
                        .font(.title2)
                        .foregroundStyle(Color.yellow)
                        .transition(.scale.combined(with: .opacity))
                        .offset(x: isLandscape ? 80 * scale : 40 * scale, y: isLandscape ? 30 * scale : 50 * scale)
                }
            }
            
            // Subtitle status row
            HStack(spacing: 8 * scale) {
                Image(systemName: isLandscape ? "arrow.left.and.right" : "arrow.up.and.down")
                    .font(.caption)
                    .foregroundStyle(.cyan)
                
                Text(isLandscape ? "Landscape Reframe (16:9)" : "Portrait Reframe (9:16)")
                    .font(.system(size: 12 * scale, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                
                Spacer()
                
                Text(showWatermark ? "Watermark Included" : "Watermark Removed!")
                    .font(.system(size: 12 * scale, weight: .bold, design: .rounded))
                    .foregroundStyle(showWatermark ? Color.red.opacity(0.8) : Color.green)
            }
            .padding(.horizontal, 8 * scale)
        }
        .onReceive(timer) { _ in
            withAnimation {
                isLandscape.toggle()
                showWatermark.toggle()
            }
        }
    }
}
