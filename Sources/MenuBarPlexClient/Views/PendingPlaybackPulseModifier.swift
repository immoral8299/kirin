import SwiftUI

struct PendingPlaybackPulseModifier: ViewModifier {
    let isActive: Bool
    @State private var isPulsing = false
    @State private var pulseTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPulsing ? 0.96 : 1)
            .opacity(isPulsing ? 0.68 : 1)
            .animation(.easeInOut(duration: 0.6), value: isPulsing)
            .onAppear {
                guard isActive else { return }
                startPulsing()
            }
            .onChange(of: isActive) { newValue in
                if newValue {
                    startPulsing()
                } else {
                    stopPulsing()
                }
            }
            .onDisappear(perform: stopPulsing)
    }

    private func startPulsing() {
        pulseTask?.cancel()
        isPulsing = true
        pulseTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(0.6))
                guard !Task.isCancelled else { break }
                isPulsing.toggle()
            }
        }
    }

    private func stopPulsing() {
        pulseTask?.cancel()
        pulseTask = nil
        isPulsing = false
    }
}

extension View {
    func pendingPlaybackPulse(_ isActive: Bool) -> some View {
        modifier(PendingPlaybackPulseModifier(isActive: isActive))
    }
}
