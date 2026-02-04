import SwiftUI

// MARK: - Splash Screen

/// Elegant animated splash screen
struct SplashScreenView: View {
    @State private var iconScale: CGFloat = 0.5
    @State private var iconOpacity: Double = 0
    @State private var titleOpacity: Double = 0
    @State private var subtitleOpacity: Double = 0
    @State private var pulseScale: CGFloat = 1
    @Binding var isFinished: Bool
    
    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [
                    Color(.systemBackground),
                    Color.blue.opacity(0.05)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            VStack(spacing: 24) {
                Spacer()
                
                // Animated icon with pulse effect
                ZStack {
                    // Pulse rings
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .stroke(Color.blue.opacity(0.2 - Double(i) * 0.05), lineWidth: 2)
                            .frame(width: 140 + CGFloat(i * 30), height: 140 + CGFloat(i * 30))
                            .scaleEffect(pulseScale)
                            .opacity(iconOpacity * (1 - Double(i) * 0.2))
                    }
                    
                    // Icon background
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.blue, Color.blue.opacity(0.8)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 120, height: 120)
                        .shadow(color: .blue.opacity(0.3), radius: 20, x: 0, y: 10)
                    
                    // Icon
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 50, weight: .medium))
                        .foregroundColor(.white)
                }
                .scaleEffect(iconScale)
                .opacity(iconOpacity)
                
                // Title
                Text("BLE Mesh")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .opacity(titleOpacity)
                
                // Subtitle
                Text("Decentralized Messaging")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.secondary)
                    .opacity(subtitleOpacity)
                
                Spacer()
                Spacer()
            }
        }
        .onAppear {
            // Animate icon
            withAnimation(.spring(response: 0.8, dampingFraction: 0.6)) {
                iconScale = 1
                iconOpacity = 1
            }
            
            // Animate title
            withAnimation(.easeOut(duration: 0.5).delay(0.3)) {
                titleOpacity = 1
            }
            
            // Animate subtitle
            withAnimation(.easeOut(duration: 0.5).delay(0.5)) {
                subtitleOpacity = 1
            }
            
            // Pulse animation
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true).delay(0.5)) {
                pulseScale = 1.1
            }
            
            // Transition after delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation(.easeInOut(duration: 0.5)) {
                    isFinished = true
                }
            }
        }
    }
}

// MARK: - Onboarding Page Model

/// Onboarding page data model
struct OnboardingPage: Identifiable {
    let id = UUID()
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    let description: String
}

/// Elegant minimal onboarding for first-time users
struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var currentPage = 0
    
    private let pages: [OnboardingPage] = [
        OnboardingPage(
            icon: "antenna.radiowaves.left.and.right.circle.fill",
            iconColor: .blue,
            title: "Welcome to BLE Mesh",
            subtitle: "Decentralized Messaging",
            description: "Send messages without internet or cell service. Your device becomes part of a wireless mesh network with nearby devices."
        ),
        OnboardingPage(
            icon: "point.3.connected.trianglepath.dotted",
            iconColor: .purple,
            title: "Multi-Hop Routing",
            subtitle: "Messages Find Their Way",
            description: "Messages automatically hop through intermediate devices to reach their destination, even if you're not directly connected."
        ),
        OnboardingPage(
            icon: "person.2.fill",
            iconColor: .green,
            title: "Direct & Group Chat",
            subtitle: "Stay Connected",
            description: "Chat with individuals or create groups for team communication. Perfect for events, emergencies, or off-grid areas."
        ),
        OnboardingPage(
            icon: "chart.bar.fill",
            iconColor: .orange,
            title: "Route Quality",
            subtitle: "Smart Messaging",
            description: "See the reliability of paths to your peers and track message delivery status across every hop in the mesh."
        ),
        OnboardingPage(
            icon: "bolt.fill",
            iconColor: .yellow,
            title: "Ready to Connect",
            subtitle: "Let's Get Started",
            description: "Enable Bluetooth and start discovering nearby devices. The more devices in range, the stronger your mesh network becomes."
        )
    ]
    
    var body: some View {
        ZStack {
            // Background
            Color(.systemBackground)
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Skip button
                HStack {
                    Spacer()
                    if currentPage < pages.count - 1 {
                        Button("Skip") {
                            withAnimation {
                                completeOnboarding()
                            }
                        }
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding()
                    }
                }
                .frame(height: 50)
                
                // Page content
                TabView(selection: $currentPage) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                        OnboardingPageView(page: page)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut, value: currentPage)
                
                // Page indicator
                HStack(spacing: 8) {
                    ForEach(0..<pages.count, id: \.self) { index in
                        Circle()
                            .fill(index == currentPage ? Color.blue : Color.gray.opacity(0.3))
                            .frame(width: index == currentPage ? 10 : 8, height: index == currentPage ? 10 : 8)
                    }
                }
                .padding(.bottom, 30)
                
                // Action button
                Button(action: {
                    withAnimation(.spring(response: 0.4)) {
                        if currentPage < pages.count - 1 {
                            currentPage += 1
                        } else {
                            completeOnboarding()
                        }
                    }
                }) {
                    HStack {
                        Text(currentPage < pages.count - 1 ? "Continue" : "Get Started")
                            .fontWeight(.semibold)
                        
                        Image(systemName: currentPage < pages.count - 1 ? "arrow.right" : "checkmark")
                            .font(.body.weight(.semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(
                        LinearGradient(
                            colors: [.blue, .blue.opacity(0.8)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(16)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
    }
    
    private func completeOnboarding() {
        hasCompletedOnboarding = true
    }
}

/// Individual onboarding page view
struct OnboardingPageView: View {
    let page: OnboardingPage
    
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            
            // Icon with animated background
            ZStack {
                Circle()
                    .fill(page.iconColor.opacity(0.1))
                    .frame(width: 160, height: 160)
                
                Circle()
                    .fill(page.iconColor.opacity(0.15))
                    .frame(width: 120, height: 120)
                
                Image(systemName: page.icon)
                    .font(.system(size: 60))
                    .foregroundColor(page.iconColor)
            }
            .padding(.bottom, 20)
            
            // Title
            Text(page.title)
                .font(.title)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
            
            // Subtitle
            Text(page.subtitle)
                .font(.headline)
                .foregroundColor(page.iconColor)
                .multilineTextAlignment(.center)
            
            // Description
            Text(page.description)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, 32)
                .fixedSize(horizontal: false, vertical: true)
            
            Spacer()
            Spacer()
        }
        .padding()
    }
}

// MARK: - Root View Controller

/// Root view that manages splash, onboarding, and main app flow
struct RootView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var splashFinished = false
    @EnvironmentObject var bluetoothManager: BluetoothManager
    @EnvironmentObject var routingService: RoutingService
    @EnvironmentObject var messageRelayService: MessageRelayService
    @EnvironmentObject var chatViewModel: ChatViewModel
    
    var body: some View {
        ZStack {
            // Main content layer
            Group {
                if hasCompletedOnboarding {
                    ContentView()
                } else {
                    OnboardingView()
                }
            }
            .opacity(splashFinished ? 1 : 0)
            
            // Splash screen layer
            if !splashFinished {
                SplashScreenView(isFinished: $splashFinished)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: splashFinished)
        .animation(.easeInOut(duration: 0.3), value: hasCompletedOnboarding)
    }
}

// MARK: - Onboarding Replay View (for Settings)

/// Version of onboarding that can be dismissed (for replay from Settings)
struct OnboardingReplayView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var currentPage = 0
    
    private let pages: [OnboardingPage] = [
        OnboardingPage(
            icon: "antenna.radiowaves.left.and.right.circle.fill",
            iconColor: .blue,
            title: "Welcome to BLE Mesh",
            subtitle: "Decentralized Messaging",
            description: "Send messages without internet or cell service. Your device becomes part of a wireless mesh network with nearby devices."
        ),
        OnboardingPage(
            icon: "point.3.connected.trianglepath.dotted",
            iconColor: .purple,
            title: "Multi-Hop Routing",
            subtitle: "Messages Find Their Way",
            description: "Messages automatically hop through intermediate devices to reach their destination, even if you're not directly connected."
        ),
        OnboardingPage(
            icon: "person.2.fill",
            iconColor: .green,
            title: "Direct & Group Chat",
            subtitle: "Stay Connected",
            description: "Chat with individuals or create groups for team communication. Perfect for events, emergencies, or off-grid areas."
        ),
        OnboardingPage(
            icon: "chart.bar.fill",
            iconColor: .orange,
            title: "Route Quality",
            subtitle: "Smart Messaging",
            description: "See the reliability of paths to your peers and track message delivery status across every hop in the mesh."
        ),
        OnboardingPage(
            icon: "bolt.fill",
            iconColor: .yellow,
            title: "Ready to Connect",
            subtitle: "Let's Get Started",
            description: "Enable Bluetooth and start discovering nearby devices. The more devices in range, the stronger your mesh network becomes."
        )
    ]
    
    var body: some View {
        NavigationView {
            ZStack {
                Color(.systemBackground)
                    .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Page content
                    TabView(selection: $currentPage) {
                        ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                            OnboardingPageView(page: page)
                                .tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    
                    // Page indicator
                    HStack(spacing: 8) {
                        ForEach(0..<pages.count, id: \.self) { index in
                            Circle()
                                .fill(index == currentPage ? Color.blue : Color.gray.opacity(0.3))
                                .frame(width: index == currentPage ? 10 : 8, height: index == currentPage ? 10 : 8)
                        }
                    }
                    .padding(.bottom, 30)
                    
                    // Navigation buttons
                    HStack(spacing: 16) {
                        if currentPage > 0 {
                            Button {
                                withAnimation { currentPage -= 1 }
                            } label: {
                                HStack {
                                    Image(systemName: "arrow.left")
                                    Text("Back")
                                }
                                .foregroundColor(.blue)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(12)
                            }
                        }
                        
                        Button {
                            if currentPage < pages.count - 1 {
                                withAnimation { currentPage += 1 }
                            } else {
                                dismiss()
                            }
                        } label: {
                            HStack {
                                Text(currentPage < pages.count - 1 ? "Next" : "Done")
                                if currentPage < pages.count - 1 {
                                    Image(systemName: "arrow.right")
                                }
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color.blue)
                            .cornerRadius(12)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 30)
                }
            }
            .navigationTitle("How It Works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }
}
