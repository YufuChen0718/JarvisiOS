import SwiftUI

enum JarvisDesign {
    static let accent = Color(red: 0.27, green: 0.88, blue: 1.0)
    static let accentDeep = Color(red: 0.14, green: 0.47, blue: 0.98)
    static let success = Color(red: 0.34, green: 0.94, blue: 0.68)
    static let warning = Color(red: 1.0, green: 0.71, blue: 0.28)
    static let danger = Color(red: 1.0, green: 0.36, blue: 0.43)

    static let background = LinearGradient(
        colors: [
            Color(red: 0.025, green: 0.045, blue: 0.085),
            Color(red: 0.035, green: 0.075, blue: 0.12),
            Color(red: 0.02, green: 0.03, blue: 0.065)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

/// A translucent card that reads well over a live camera feed.
struct JarvisPanel: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            }
    }
}

extension View {
    func jarvisPanel(radius: CGFloat = 28) -> some View {
        modifier(JarvisPanel(radius: radius))
    }
}

struct StatusPill: View {
    let phase: AssistantPhase

    private var color: Color {
        switch phase {
        case .idle, .completed: JarvisDesign.success
        case .listening: JarvisDesign.accent
        case .thinking, .answering: JarvisDesign.warning
        case .speaking: JarvisDesign.accent
        case .failed: JarvisDesign.danger
        }
    }

    private var isActive: Bool {
        [.listening, .thinking, .answering, .speaking].contains(phase)
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.8), radius: 6)
                .opacity(isActive ? 1 : 0.6)
            Text(phase.statusText)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.black.opacity(0.35), in: Capsule())
    }
}
