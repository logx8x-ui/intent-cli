import SwiftUI

/// Header and footer own their measured height. Only the remaining canvas is
/// offered to window packing, so visible controls never borrow caption space.
struct OverviewChromeLayout: Layout {
    static let contentGap: CGFloat = 12

    struct Frames {
        let header: CGRect
        let canvas: CGRect
        let footer: CGRect
    }

    static func frames(in bounds: CGRect, headerHeight: CGFloat, footerHeight: CGFloat) -> Frames {
        let footerHeight = min(max(0, footerHeight), bounds.height)
        let headerHeight = min(max(0, headerHeight), max(0, bounds.height - footerHeight))
        let freeHeight = max(0, bounds.height - headerHeight - footerHeight)
        let gap = min(contentGap, freeHeight / 2)
        return Frames(
            header: CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: headerHeight),
            canvas: CGRect(x: bounds.minX, y: bounds.minY + headerHeight + gap,
                           width: bounds.width, height: max(0, freeHeight - gap * 2)),
            footer: CGRect(x: bounds.minX, y: bounds.maxY - footerHeight,
                           width: bounds.width, height: footerHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let chromeProposal = ProposedViewSize(width: bounds.width, height: nil)
        let frames = Self.frames(in: bounds,
            headerHeight: subviews[0].sizeThatFits(chromeProposal).height,
            footerHeight: subviews[2].sizeThatFits(chromeProposal).height)
        for (view, frame) in zip(subviews, [frames.header, frames.canvas, frames.footer]) {
            view.place(at: frame.origin, anchor: .topLeading,
                       proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}
