import SwiftUI

// Shared Liquid Glass building blocks (iOS 26 SwiftUI: `glassEffect(_:in:)`,
// `GlassEffectContainer`, `.glass` / `.glassProminent` button styles).
// Accessibility: with Reduce Transparency the cards fall back to an opaque
// grouped background; with Increase Contrast they gain a visible outline.

/// Soft animated-free mesh gradient behind every screen, so the glass has
/// something to refract. Plain grouped background when Reduce Transparency is on.
struct AppBackground: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if reduceTransparency {
                Color(uiColor: .systemGroupedBackground)
            } else {
                MeshGradient(
                    width: 3, height: 3,
                    points: [
                        [0, 0], [0.5, 0], [1, 0],
                        [0, 0.5], [0.55, 0.45], [1, 0.5],
                        [0, 1], [0.5, 1], [1, 1],
                    ],
                    colors: scheme == .dark ? Self.dark : Self.light
                )
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private static let light: [Color] = [
        Color(red: 0.86, green: 0.93, blue: 1.00), Color(red: 0.93, green: 0.95, blue: 1.00), Color(red: 0.95, green: 0.90, blue: 1.00),
        Color(red: 0.88, green: 0.97, blue: 0.97), Color(red: 0.97, green: 0.97, blue: 0.99), Color(red: 0.99, green: 0.93, blue: 0.95),
        Color(red: 0.90, green: 0.96, blue: 0.92), Color(red: 0.95, green: 0.96, blue: 1.00), Color(red: 0.92, green: 0.92, blue: 1.00),
    ]

    private static let dark: [Color] = [
        Color(red: 0.05, green: 0.10, blue: 0.22), Color(red: 0.07, green: 0.08, blue: 0.18), Color(red: 0.16, green: 0.08, blue: 0.24),
        Color(red: 0.03, green: 0.15, blue: 0.18), Color(red: 0.06, green: 0.07, blue: 0.12), Color(red: 0.20, green: 0.07, blue: 0.14),
        Color(red: 0.04, green: 0.13, blue: 0.10), Color(red: 0.06, green: 0.08, blue: 0.16), Color(red: 0.10, green: 0.08, blue: 0.22),
    ]
}

/// Corner radii used across the app: cards and rows; nested shapes use `ConcentricRectangle`.
enum GlassMetrics {
    static let card: CGFloat = 26
    static let row: CGFloat = 20
}

/// Rounded glass card. `tint` suggests state (e.g. orange = needs attention).
struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = GlassMetrics.card
    var tint: Color?
    var interactive = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if reduceTransparency {
                content.background(Color(uiColor: .secondarySystemGroupedBackground), in: shape)
            } else {
                content.glassEffect(glass, in: shape)
            }
        }
        .overlay {
            if contrast == .increased || reduceTransparency {
                shape.strokeBorder(.primary.opacity(contrast == .increased ? 0.45 : 0.12), lineWidth: 1)
            }
        }
        // The glass background is not hit-testable: without this, a card used as a
        // NavigationLink / Button label only reacts to taps on its text and icons.
        .contentShape(shape)
    }

    private var glass: Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint.opacity(0.18)) }
        if interactive { g = g.interactive() }
        return g
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = GlassMetrics.card, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius, tint: tint, interactive: interactive))
    }

    /// Screen chrome shared by all tabs: mesh background, hidden list/form backgrounds.
    func glassScreen() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background { AppBackground() }
    }
}

/// Section title used above glass cards (lists use their own headers).
struct CardHeader: View {
    let title: LocalizedStringKey
    var systemImage: String?

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(title)
        }
        .font(.footnote.weight(.semibold))
        .textCase(.uppercase)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Floating circular glass action button (bottom trailing), e.g. "Add Device".
struct FloatingActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let identifier: String
    let action: () -> Void
    @ScaledMetric(relativeTo: .title2) private var size: CGFloat = 58

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2.weight(.semibold))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
        .padding(.trailing, 20)
        .padding(.bottom, 16)
    }
}
