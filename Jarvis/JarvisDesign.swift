import SwiftUI

// MARK: - Aether Intelligence palette

enum JarvisDesign {
    static let surface       = Color(hex: 0x131314)
    static let surfaceDeep   = Color(hex: 0x0A0A0B)
    static let onSurface     = Color(hex: 0xE5E2E3)
    static let onSurfaceDim  = Color(hex: 0xBBCABF)
    static let outline       = Color(hex: 0x86948A)

    static let primary       = Color(hex: 0x4EDEA3)   // emerald — active intelligence
    static let primaryDeep   = Color(hex: 0x10B981)
    static let secondary     = Color(hex: 0x4CD7F6)   // cyan — data flow / the orb
    static let secondaryDeep = Color(hex: 0x03B5D3)
    static let coreHighlight = Color(hex: 0xB5F1FF)

    // Compatibility aliases used across the app.
    static let accent  = primary
    static let success = primary
    static let warning = Color(hex: 0xFFC15A)
    static let danger  = Color(hex: 0xFFB4AB)

    static let background = LinearGradient(
        colors: [Color(hex: 0x131314), Color(hex: 0x0C0C0D), Color(hex: 0x050505)],
        startPoint: .top, endPoint: .bottom
    )

    /// Radial HUD vignette that keeps overlaid controls legible over the camera.
    static let hudVignette = RadialGradient(
        colors: [.clear, Color.black.opacity(0.35), Color.black.opacity(0.78)],
        center: .center, startRadius: 120, endRadius: 620
    )
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

// MARK: - Glassmorphism

struct GlassBackground: ViewModifier {
    var cornerRadius: CGFloat = 16
    var active: Bool = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay(shape.fill(JarvisDesign.surface.opacity(0.35)))
            }
            .overlay {
                shape.stroke(JarvisDesign.primaryDeep.opacity(active ? 0.45 : 0.22), lineWidth: 1)
            }
            .overlay(alignment: .top) {
                // inner top highlight — light hitting the glass edge
                shape.stroke(
                    LinearGradient(colors: [.white.opacity(0.18), .clear],
                                   startPoint: .top, endPoint: .center),
                    lineWidth: 1
                )
            }
            .shadow(color: .black.opacity(0.5), radius: 18, y: 10)
            .shadow(color: active ? JarvisDesign.primary.opacity(0.18) : .clear, radius: 22)
    }
}

extension View {
    func glass(cornerRadius: CGFloat = 16, active: Bool = false) -> some View {
        modifier(GlassBackground(cornerRadius: cornerRadius, active: active))
    }
    /// Kept for existing call sites.
    func jarvisPanel(radius: CGFloat = 24) -> some View {
        modifier(GlassBackground(cornerRadius: radius, active: false))
    }
}

// MARK: - Breathing status dot

struct BreathingDot: View {
    var color: Color
    var active: Bool = true
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.7))
                .scaleEffect(active && pulse ? 2.4 : 1)
                .opacity(active && pulse ? 0 : 0.6)
            Circle()
                .fill(color)
                .shadow(color: color, radius: 5)
        }
        .frame(width: 7, height: 7)
        .onAppear { if active { animate() } }
        .onChange(of: active) { _, on in if on { animate() } else { pulse = false } }
    }

    private func animate() {
        pulse = false
        withAnimation(.easeOut(duration: 2).repeatForever(autoreverses: false)) { pulse = true }
    }
}

// MARK: - Intelligence chip ("CAM: ACTIVE")

struct IntelligenceChip: View {
    var title: String
    var value: String
    var color: Color
    var showsDot: Bool = false
    var breathing: Bool = false
    var systemIcon: String? = nil

    var body: some View {
        HStack(spacing: 7) {
            if showsDot {
                BreathingDot(color: color, active: breathing)
            } else if let systemIcon {
                Image(systemName: systemIcon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
            }
            Text("\(title): \(value)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(color)
        }
    }
}

// MARK: - Logo mark (reactor ripple)

struct LogoMark: View {
    var body: some View {
        ZStack {
            Circle().stroke(JarvisDesign.primary.opacity(0.9), lineWidth: 1.4)
            Circle().stroke(JarvisDesign.secondary.opacity(0.55), lineWidth: 1).padding(5)
            Circle().fill(JarvisDesign.primary).frame(width: 6, height: 6)
                .shadow(color: JarvisDesign.primary, radius: 5)
        }
        .frame(width: 38, height: 38)
        .padding(3)
        .background(Circle().fill(JarvisDesign.surface.opacity(0.5)))
        .overlay(Circle().stroke(JarvisDesign.primaryDeep.opacity(0.35), lineWidth: 1))
        .shadow(color: JarvisDesign.primary.opacity(0.35), radius: 12)
    }
}

// MARK: - Reactor glyph + pulse ring (for the mic orb)

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// Mark-VI style arc reactor: dark structure (bezel, segmented coil ring,
/// central inverted triangle, struts + nodes) drawn over the glowing cyan core,
/// so the gaps read as light.
struct ReactorGlyph: View {
    var structureColor: Color = Color(hex: 0x05222A)

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height)
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let R = s / 2
            let color = GraphicsContext.Shading.color(structureColor)

            // 1. Outer bezel ring
            var bezel = Path()
            bezel.addArc(center: c, radius: R * 0.90, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
            ctx.stroke(bezel, with: color, lineWidth: s * 0.11)

            // 2. Segmented coil ring (radial ribs + bounding arcs)
            let rIn = R * 0.50
            let rOut = R * 0.82
            for rr in [rIn, rOut] {
                var arc = Path()
                arc.addArc(center: c, radius: rr, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
                ctx.stroke(arc, with: color, lineWidth: s * 0.028)
            }
            let segments = 9
            for i in 0..<segments {
                let a = Double(i) / Double(segments) * 2 * .pi - .pi / 2
                let p1 = CGPoint(x: c.x + CGFloat(cos(a)) * rIn, y: c.y + CGFloat(sin(a)) * rIn)
                let p2 = CGPoint(x: c.x + CGFloat(cos(a)) * rOut, y: c.y + CGFloat(sin(a)) * rOut)
                var rib = Path()
                rib.move(to: p1)
                rib.addLine(to: p2)
                ctx.stroke(rib, with: color, lineWidth: s * 0.05)
            }

            // 3. Central inverted triangle (apex down)
            let triR = R * 0.36
            let verts = (0..<3).map { i -> CGPoint in
                let a = Double(i) / 3 * 2 * .pi + .pi / 2
                return CGPoint(x: c.x + CGFloat(cos(a)) * triR, y: c.y + CGFloat(sin(a)) * triR)
            }
            var tri = Path()
            tri.move(to: verts[0])
            tri.addLine(to: verts[1])
            tri.addLine(to: verts[2])
            tri.closeSubpath()
            ctx.stroke(tri, with: color, lineWidth: s * 0.055)

            // 4. Struts from each vertex out to the coil ring, with nodes
            for v in verts {
                let a = atan2(v.y - c.y, v.x - c.x)
                let outer = CGPoint(x: c.x + CGFloat(cos(a)) * rIn, y: c.y + CGFloat(sin(a)) * rIn)
                var strut = Path()
                strut.move(to: v)
                strut.addLine(to: outer)
                ctx.stroke(strut, with: color, lineWidth: s * 0.03)

                let n = s * 0.075
                ctx.fill(Path(ellipseIn: CGRect(x: v.x - n / 2, y: v.y - n / 2, width: n, height: n)), with: color)
            }
            let cn = s * 0.07
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - cn / 2, y: c.y - cn / 2, width: cn, height: cn)), with: color)
        }
    }
}

struct PulseRing: View {
    var color: Color
    var active: Bool
    var delay: Double = 0
    @State private var expand = false

    var body: some View {
        Circle()
            .stroke(color.opacity(0.55), lineWidth: 2)
            .scaleEffect(expand ? 1.8 : 1)
            .opacity(expand ? 0 : 0.7)
            .onAppear { if active { start() } }
            .onChange(of: active) { _, on in if on { start() } else { expand = false } }
    }

    private func start() {
        expand = false
        withAnimation(.easeOut(duration: 2.2).repeatForever(autoreverses: false).delay(delay)) {
            expand = true
        }
    }
}
