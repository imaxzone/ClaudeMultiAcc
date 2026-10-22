import AppKit
import InstanceBuilder
import SwiftUI

extension AppMenuStyle {
  // MARK: Header (the Claude update check)

  /// The line starts where the rows' text does; ↻'s square ends where the cards and the grid do, so the symbol lines
  /// up with the switch and «⌘Q» below.
  static let headerPadding = EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 4)
  static let headerGap: CGFloat = 8
  /// ↻'s square: the hover and pressed fill, and the focus ring around it.
  static let headerButton: CGFloat = 22
  static let headerSymbol = Font.system(size: 12, weight: .semibold)
  /// How far a long line may shrink before it truncates (only with a very long version).
  static let headerLineScale: CGFloat = 0.85
  /// ↻ while a check runs and Reduce Motion is on: still, dimmed like a disabled control.
  static let headerStillOpacity: Double = 0.5
}

/// The menu's top row, there in every state: on the left what the Claude update check is doing («Проверяю
/// обновления Claude…», «Скачиваю Claude 3.1623.3 — 42 %», a result), or while idle which Claude the clones are built
/// from («Claude 3.1623.3»); a failed check's line is red. On the right ↻ «Проверить обновления Claude»: it turns and
/// is disabled while a check runs, and clicking it keeps the menu open.
struct ClaudeUpdateHeaderView: View {
  let status: ClaudeUpdateStatus
  /// The newest Claude the clones are built from, for the idle line.
  let version: String?
  let isHighlighted: Bool
  let hasFocusRing: Bool
  let onCheck: () -> Void
  let onHover: (Bool) -> Void

  private var line: String? { ClaudeUpdateText.line(status, current: version) }

  private var isFailed: Bool {
    if case .failed = status { return true }
    return false
  }

  var body: some View {
    HStack(spacing: AppMenuStyle.headerGap) {
      Text(line ?? "")
        .font(AppMenuStyle.Fonts.detail.monospacedDigit())
        .foregroundStyle(isFailed ? AnyShapeStyle(AppMenuStyle.destructive) : AnyShapeStyle(.secondary))
        .lineLimit(1)
        .minimumScaleFactor(AppMenuStyle.headerLineScale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(line == nil)
        .accessibilityAddTraits(status.isWorking ? .updatesFrequently : [])
      Button(action: onCheck) {
        CheckClaudeSymbol(isWorking: status.isWorking)
      }
      .buttonStyle(HeaderButtonStyle(isHighlighted: isHighlighted, hasFocusRing: hasFocusRing, isBusy: status.isWorking))
      .disabled(status.isWorking)
      .menuControl(onHover: onHover)
      .help(ClaudeUpdateText.buttonLabel)
      .accessibilityLabel(ClaudeUpdateText.buttonLabel)
    }
    .padding(AppMenuStyle.headerPadding)
    .accessibilityElement(children: .contain)
  }
}

/// ↻, turning clockwise while a check runs. With Reduce Motion it stays still and dimmed instead; the line next to it
/// says what is going on.
struct CheckClaudeSymbol: View {
  let isWorking: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Image(systemName: "arrow.clockwise")
      .font(AppMenuStyle.headerSymbol)
      .symbolEffect(
        .rotate.clockwise, options: .repeat(.continuous),
        isActive: Self.spins(isWorking: isWorking, reduceMotion: reduceMotion))
      .opacity(Self.opacity(isWorking: isWorking, reduceMotion: reduceMotion))
      .accessibilityHidden(true)
  }

  static func spins(isWorking: Bool, reduceMotion: Bool) -> Bool { isWorking && !reduceMotion }

  static func opacity(isWorking: Bool, reduceMotion: Bool) -> Double {
    isWorking && reduceMotion ? AppMenuStyle.headerStillOpacity : 1
  }
}

/// ↻'s square, highlighted like the menu's tiles: a light fill on hover and from the keyboard (with the system focus
/// ring then), darker when pressed. While a check runs it has no fill, hover or press: nothing there to click.
struct HeaderButtonStyle: ButtonStyle {
  let isHighlighted: Bool
  let hasFocusRing: Bool
  var isBusy = false

  func makeBody(configuration: Configuration) -> some View {
    let shape = RoundedRectangle(cornerRadius: AppMenuStyle.rowCorner, style: .continuous)
    let live = !isBusy
    let side = AppMenuStyle.headerButton
    configuration.label
      .foregroundStyle(live && isHighlighted ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
      .frame(width: side, height: side)
      .background(shape.fill(fill(pressed: live && configuration.isPressed, highlighted: live && isHighlighted)))
      .overlay(shape.strokeBorder(AppMenuStyle.focusRing, lineWidth: 2.5).opacity(hasFocusRing ? 1 : 0))
      .contentShape(shape)
      .animation(AppMenuStyle.liveHighlight, value: configuration.isPressed)
  }

  private func fill(pressed: Bool, highlighted: Bool) -> Color {
    if pressed { return AppMenuStyle.tilePressed }
    return highlighted ? AppMenuStyle.tileHover : .clear
  }
}
