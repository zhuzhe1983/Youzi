import SwiftUI

/// Prefer one native horizontal radio group. At narrow widths or large type,
/// fall back to the native vertical group rather than clipping any option.
/// Both variants retain AppKit's radio semantics and arrow-key navigation.
private struct CompactRadioGroup: ViewModifier {
    func body(content: Content) -> some View {
        ViewThatFits(in: .horizontal) {
            content.pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .fixedSize(horizontal: true, vertical: true)
            content.pickerStyle(.radioGroup)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension View {
    func compactRadioGroup() -> some View { modifier(CompactRadioGroup()) }
}
