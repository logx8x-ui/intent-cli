import SwiftUI

/// Static placeholders respect Reduce Motion without a spinning/pulsing surface.
struct WindowLoadingSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                ForEach(0..<3) { _ in Circle().fill(.white.opacity(0.2)).frame(width: 5, height: 5) }
            }
            RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.10)).frame(height: 7)
            RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.07)).frame(maxWidth: .infinity, maxHeight: .infinity)
        }.accessibilityLabel("Loading window preview")
    }
}

struct OverviewLoadingSkeleton: View {
    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 26) {
                ForEach(0..<3) { index in
                    WindowLoadingSkeleton().padding(15)
                        .frame(height: proxy.size.height * (index == 1 ? 0.52 : 0.39))
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.15)))
                }
            }.frame(maxHeight: .infinity)
        }.accessibilityElement(children: .ignore).accessibilityLabel("Loading window previews")
    }
}
