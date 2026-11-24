import SwiftUI
import UIKit

/// Visible card surface for device media; keep Emby poster layouts unchanged.
struct DeviceMediaCardBackground: ViewModifier {
    var enabled = true
    func body(content: Content) -> some View {
        content
            .background {
                if enabled {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(VesperTheme.mediaCardBackground)
                }
            }
    }
}

struct MediaCardBackdrop: View {
    var showsMissingArtwork = false
    var iconCenterY: CGFloat = 0.5
    var missingArtworkSymbol: String? = nil

    var body: some View {
        VesperTheme.mediaCardBackground
            .overlay {
                if showsMissingArtwork {
                    GeometryReader { geometry in
                        let size = geometry.size
                        Image(systemName: missingArtworkSymbol ?? AppSection.media.symbol)
                            .font(.system(size: min(44, min(size.width, size.height) * 0.28)))
                            .foregroundStyle(.secondary)
                            .position(x: size.width / 2, y: size.height * iconCenterY)
                    }
                }
            }
            .accessibilityHidden(true)
    }
}

struct MediaArtworkBorder: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat
    var isSelected = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        let stroke = colorScheme == .dark ? Color.white : Color.black
        content
            .clipShape(shape)
            .overlay {
                shape.strokeBorder((isSelected ? Color.accentColor : stroke).opacity(0.5), lineWidth: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

extension View {
    func mediaArtworkBorder(cornerRadius: CGFloat = 12, isSelected: Bool = false) -> some View {
        modifier(MediaArtworkBorder(cornerRadius: cornerRadius, isSelected: isSelected))
    }
}

