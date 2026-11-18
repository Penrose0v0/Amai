import SwiftUI
import AppKit

// Liquid Glass, back-deployed. The whole chat panel is one clear
// `NSGlassEffectView` (macOS 26+); one surface → one consistent tone. Legibility
// comes from ChatView's top/bottom gradient scrims and the message bubbles'
// frosted backgrounds, not from tinting the glass. Older systems fall back to
// `VisualEffectBlur` via `chatCardSurface`.

enum PanelGlass {
    static let cornerRadius: CGFloat = 25

    // MARK: Edge highlight (the bright rim around the panel). Tune in chatCardSurface's use.
    /// Strength of the top-lit edge highlight (0 = none).
    static let highlightOpacity: Double = 0.0
    /// Width of the highlight stroke, in points.
    static let highlightWidth: CGFloat = 0.5

    // Drop shadow: the macOS window shadow (panel.hasShadow) — matches Spotlight.

    /// A Liquid Glass card: `host` on top of the glass, inside a rounded clip
    /// that removes the glass's built-in drop shadow. See `GlassCardView`.
    @available(macOS 26.0, *)
    static func glassCard(_ host: NSView) -> NSView { GlassCardView(host: host) }
}

/// Hosts the whole ChatView inside one window-level Liquid Glass panel.
///
/// - `host` is the glass's `contentView` (the documented use), which keeps the
///   panel one consistent tone (glass laid merely *behind* the host sampled its
///   own pixels and diverged light/dark instead).
/// - The rounded, masked layer clips away the glass's own boxy drop shadow (not
///   removable via `hasShadow` / `NSView.shadow` / `layer.shadowOpacity`).
@available(macOS 26.0, *)
final class GlassCardView: NSView {
    init(host: NSView) {
        super.init(frame: .zero)

        // Rounded clip masks away the glass's own boxy self-shadow.
        wantsLayer = true
        layer?.cornerRadius = PanelGlass.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        let glass = NSGlassEffectView()
        glass.cornerRadius = PanelGlass.cornerRadius
        glass.style = .clear
        glass.tintColor = nil
        glass.contentView = host
        glass.translatesAutoresizingMaskIntoConstraints = false

        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

extension View {
    /// Message-bubble background: a translucent color fill (so `tint` alpha
    /// directly controls transparency — 0 is fully see-through), plus an optional
    /// backdrop-blur `blur` material, a top-lit `rimHighlight` edge, and a soft
    /// drop `shadow`. Deliberately NOT `.glassEffect`: SwiftUI's Liquid Glass
    /// can't refract the desktop behind this borderless panel, so it renders as
    /// an opaque frosted body a zero-alpha tint can't make transparent — a plain
    /// color over the panel's clear glass is what actually reads as transparent.
    func bubbleGlass(
        tint: Color? = nil,
        cornerRadius: CGFloat = 12,
        blur: Material? = nil,
        rimHighlight: Double = 0.0,
        shadow: Double = 0.25
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background {
                // Material first (blurs the backdrop), tint color layered on top.
                if let blur { shape.fill(blur) }
                if let tint { shape.fill(tint) }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(rimHighlight), .white.opacity(rimHighlight * 0.15)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            }
            .shadow(color: .black.opacity(shadow), radius: 8, y: 3)
    }

    /// On macOS 26+ the window provides the glass, so the card only clips its
    /// content and draws a hairline edge. On older systems it renders the
    /// standalone frosted card.
    @ViewBuilder
    func chatCardSurface(cornerRadius: CGFloat = PanelGlass.cornerRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // Top-lit edge highlight (brighter at the top, fading down), tunable via
        // PanelGlass.highlight*.
        let highlight = shape.strokeBorder(
            LinearGradient(
                colors: [
                    .white.opacity(PanelGlass.highlightOpacity),
                    .white.opacity(PanelGlass.highlightOpacity * 0.3),
                ],
                startPoint: .top, endPoint: .bottom
            ),
            lineWidth: PanelGlass.highlightWidth
        )
        if #available(macOS 26.0, *) {
            self.clipShape(shape).overlay(highlight)
        } else {
            self
                .background(Color.black.opacity(0.2))
                .background(VisualEffectBlur())
                .clipShape(shape)
                .overlay(highlight)
        }
    }
}
