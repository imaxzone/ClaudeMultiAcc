import AppKit
import InstanceBuilder
import SwiftUI

/// The two choices under the alert's title, as cards with a radio mark, and the footer.
struct DeleteDialogView: View {
  static let width: CGFloat = 400

  let model: DeleteDialogModel

  var body: some View {
    let text = model.text
    VStack(alignment: .leading, spacing: 8) {
      DeleteOptionCard(option: text.appOnly, selected: model.choice == .appOnly) { model.choice = .appOnly }
      DeleteOptionCard(option: text.everything, selected: model.choice == .everything) { model.choice = .everything }
      Text(text.footer)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }
    .frame(width: Self.width, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
  }
}

/// «Только приложение — 632 МБ», then what goes (red), the folder that goes with it, and what stays (green). The whole
/// card selects it.
struct DeleteOptionCard: View {
  let option: DeleteDialogText.Option
  let selected: Bool
  let select: () -> Void

  private static let radius: CGFloat = 9

  var body: some View {
    Button(action: select) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
          .foregroundStyle(selected ? Color.accentColor : Color.secondary)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          Text("\(Text(option.label).fontWeight(.semibold)) — \(option.size)")
            .font(.body)
            .monospacedDigit()
          Text(option.removes).foregroundStyle(DeleteDialogColors.removes)
          if let detail = option.detail {
            Text(detail)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .lineLimit(2)
              .truncationMode(.middle)
              .textSelection(.enabled)
          }
          Text(option.keeps).foregroundStyle(DeleteDialogColors.keeps)
        }
        .font(.callout)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .background(
        RoundedRectangle(cornerRadius: Self.radius, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
      .overlay(
        RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
          .strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: selected ? 2 : 1))
      .contentShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
      .animation(.easeOut(duration: 0.15), value: selected)
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
  }
}

/// Red for what goes, green for what stays — dark enough to read on a white card, lighter in Dark Mode.
enum DeleteDialogColors {
  static let removes = adaptive(light: (0.70, 0.15, 0.12), dark: (1.00, 0.45, 0.42))
  static let keeps = adaptive(light: (0.14, 0.54, 0.24), dark: (0.40, 0.82, 0.46))

  private static func adaptive(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
      let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      let rgb = isDark ? dark : light
      return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    })
  }
}
