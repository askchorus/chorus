import SwiftUI
import AppKit

/// The "only this AI" chip both composers show once an @-mention has been picked. It is STATE,
/// not styled text: SwiftUI's TextField cannot colour a range of characters, and a chip reads
/// more clearly anyway — you see who gets the message without parsing what's in the box.
struct DirectedChip: View {
    let target: DirectedPrompt.Target
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 10, weight: .bold))
            Text(Lf("mention.chip", target.name))
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(ChorusTheme.brandOrange.opacity(0.55))
            }
            .buttonStyle(.plain)
            .help(L("mention.chipRemove"))
        }
        .foregroundColor(ChorusTheme.brandOrange)
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .padding(.vertical, 4)
        .background(Capsule().fill(ChorusTheme.brandOrange.opacity(0.12)))
        .overlay(Capsule().strokeBorder(ChorusTheme.brandOrange.opacity(0.28)))
        .fixedSize()
    }
}

/// The list that appears while "@…" is being typed: the on-screen panels, grouped by name and
/// filtered live. The highlighted row follows ↑↓ and the mouse; ↩ / ⇥ or a click picks it.
struct MentionPicker: View {
    let options: [DirectedPrompt.Target]
    @Binding var selected: Int
    let favicons: [String: NSImage]
    let onPick: (DirectedPrompt.Target) -> Void

    var body: some View {
        VStack(spacing: 2) {
            if options.isEmpty {
                Text(L("mention.noMatch"))
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
            } else {
                ForEach(Array(options.enumerated()), id: \.offset) { i, t in
                    row(t, highlighted: i == selected)
                        .onHover { if $0 { selected = i } }
                        .onTapGesture { onPick(t) }
                }
            }
        }
        .padding(4)
    }

    private func row(_ t: DirectedPrompt.Target, highlighted: Bool) -> some View {
        HStack(spacing: 8) {
            Group {
                if let icon = favicons[t.key] {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                } else {
                    Circle()
                        .fill(ProviderStyle.accent(key: t.key, host: t.host))
                        .padding(3)
                }
            }
            .frame(width: 14, height: 14)
            Text(t.name).font(.system(size: 13))
            Spacer(minLength: 0)
            if highlighted {
                Text("↩")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 5)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(0.06)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(highlighted ? Color.primary.opacity(0.07) : Color.clear))
        .contentShape(Rectangle())
    }
}
