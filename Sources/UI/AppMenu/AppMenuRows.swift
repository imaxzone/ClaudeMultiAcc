import AppKit
import Support
import SwiftUI

/// The banner's blue button: brighter on hover, darker when pressed, the system focus ring from the keyboard. While
/// busy it is a plain status in its place (secondary text, no fill, no hover or press): nothing there to click.
struct BlueButtonStyle: ButtonStyle {
  let isHighlighted: Bool
  let hasFocusRing: Bool
  var isBusy = false

  func makeBody(configuration: Configuration) -> some View {
    let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
    let live = !isBusy
    configuration.label
      .font(AppMenuStyle.Fonts.button)
      .foregroundStyle(live ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, live ? AppMenuStyle.bannerButtonInset : 0)
      .padding(.vertical, 4)
      .background(shape.fill(live ? AppMenuStyle.updateBlue : .clear))
      .overlay(shape.fill(Color.white.opacity(live && isHighlighted && !configuration.isPressed ? 0.12 : 0)))
      .overlay(shape.fill(Color.black.opacity(live && configuration.isPressed ? 0.18 : 0)))
      .overlay(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .strokeBorder(AppMenuStyle.focusRing, lineWidth: 3)
          .padding(-3)
          .opacity(live && hasFocusRing ? 1 : 0))
      .animation(AppMenuStyle.liveHighlight, value: configuration.isPressed)
  }
}

/// «Есть версия 3.1700.0 / для 2nd и mv2» with the blue «Обновить N» button; while the update runs, the button is
/// disabled and reads «Обновляется…» next to a small spinner.
struct UpdateBannerView: View {
  let banner: AppMenuBanner
  var isUpdating = false
  let isHighlighted: Bool
  let hasFocusRing: Bool
  let onUpdate: () -> Void
  let onHover: (Bool) -> Void

  /// The button keeps its size; the title gives way first (shrinking a little, then truncating), so a long version
  /// or a long button never pushes the banner wider than the menu.
  var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 1) {
        Text(banner.title)
          .font(AppMenuStyle.Fonts.bannerTitle)
          .lineLimit(1)
          .minimumScaleFactor(AppMenuStyle.bannerTitleScale)
        Text(banner.subtitle)
          .font(AppMenuStyle.Fonts.detail)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }
      .layoutPriority(1)
      .accessibilityElement(children: .combine)
      Spacer(minLength: AppMenuStyle.bannerGap)
      Button(action: onUpdate) {
        if isUpdating {
          HStack(spacing: 5) {
            MenuSpinner(size: .mini)
            Text(AppMenuStrings.updating)
          }
        } else {
          Text(banner.buttonTitle)
        }
      }
        .buttonStyle(BlueButtonStyle(isHighlighted: isHighlighted, hasFocusRing: hasFocusRing, isBusy: isUpdating))
        .disabled(isUpdating)
        .layoutPriority(2)
        .menuControl(onHover: onHover)
        .accessibilityLabel(isUpdating ? AppMenuStrings.updating : banner.buttonTitle)
        .accessibilityHint(banner.accessibilityLabel)
    }
    .padding(AppMenuStyle.bannerPadding)
    .background(card(AppMenuStyle.bannerFill))
    .padding(AppMenuStyle.cardMargin)
    .accessibilityElement(children: .contain)
  }
}

/// «Доступна новая версия ClaudeMultiAcc 1.4.0» with a «Скачать» pill under «Выйти»; the whole card is the button.
struct ReleaseRowView: View {
  let release: AppReleaseInfo
  let isHighlighted: Bool
  let hasFocusRing: Bool
  let onOpen: () -> Void
  let onHover: (Bool) -> Void

  var body: some View {
    Button(action: onOpen) {
      HStack(spacing: 9) {
        Image(nsImage: StatusGlyph.image(cutout: false))
          .renderingMode(.template)
          .foregroundStyle(.secondary)
        Text(AppMenuStrings.release(version: release.version))
          .font(AppMenuStyle.Fonts.release)
          .multilineTextAlignment(.leading)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 6)
        Text(AppMenuStrings.download)
          .font(AppMenuStyle.Fonts.button)
          .padding(.horizontal, 9)
          .padding(.vertical, 3)
          .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .fill(isHighlighted ? AppMenuStyle.pillHighlighted : AppMenuStyle.pill))
      }
      .padding(AppMenuStyle.releasePadding)
      .background(card(isHighlighted ? AppMenuStyle.tileHover : AppMenuStyle.releaseFill))
      .overlay(
        RoundedRectangle(cornerRadius: AppMenuStyle.cardCorner, style: .continuous)
          .strokeBorder(AppMenuStyle.focusRing, lineWidth: 2.5)
          .opacity(hasFocusRing ? 1 : 0))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .menuControl(onHover: onHover)
    .padding(AppMenuStyle.cardMargin)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(AppMenuStrings.release(version: release.version))
    .accessibilityAddTraits(.isButton)
    .accessibilityHint(AppMenuStrings.downloadHint)
    .accessibilityAction { onOpen() }
  }
}

/// «Открывать при старте системы» with a switch and, when needed, one short line about its state.
struct LoginRowView: View {
  let row: AppMenuLoginRow
  let isHighlighted: Bool
  let hasFocusRing: Bool
  let onToggle: () -> Void
  let onHover: (Bool) -> Void

  var body: some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 1) {
        Text(AppMenuStrings.launchAtLogin)
          .font(AppMenuStyle.Fonts.row)
          .foregroundStyle(row.isEnabled ? .primary : .secondary)
        if let subtitle = row.subtitle {
          Text(subtitle)
            .font(AppMenuStyle.Fonts.detail)
            .foregroundStyle(row.isError ? AnyShapeStyle(AppMenuStyle.destructive) : AnyShapeStyle(.secondary))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 8)
      // The whole row is the control (tap, Return, VoiceOver); the switch only shows the state.
      MenuSwitch(isOn: row.isOn, isEnabled: row.isEnabled)
    }
    .padding(AppMenuStyle.rowPadding)
    .background(rowBackground(isHighlighted ? AppMenuStyle.tileHover : .clear, focusRing: hasFocusRing))
    .contentShape(Rectangle())
    .onTapGesture { if row.isEnabled { onToggle() } }
    .onHover(perform: onHover)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(AppMenuStrings.launchAtLogin)
    .accessibilityValue(row.isOn ? AppMenuStrings.switchOn : AppMenuStrings.switchOff)
    .accessibilityHint(row.subtitle ?? "")
    .accessibilityAddTraits(.isToggle)
    .accessibilityAction { if row.isEnabled { onToggle() } }
  }
}

/// The mini switch in the system's shape, drawn in SwiftUI. An AppKit switch turns grey (even when on) whenever its
/// window does not count as active, as offscreen and possibly in this non-activating panel; this one always shows
/// the accent colour when on, and has no AppKit size to settle before the menu is measured.
struct MenuSwitch: View {
  let isOn: Bool
  let isEnabled: Bool

  var body: some View {
    let size = AppMenuStyle.switchSize
    let knob = AppMenuStyle.switchKnob
    let inset = (size.height - knob.height) / 2
    let travel = size.width - knob.width - 2 * inset
    Capsule()
      .fill(isOn ? AppMenuStyle.switchOn : AppMenuStyle.switchOff)
      .overlay(alignment: .leading) {
        Capsule()
          .fill(AppMenuStyle.switchKnobFill)
          .shadow(color: .black.opacity(0.22), radius: 0.5, y: 0.5)
          .frame(width: knob.width, height: knob.height)
          .offset(x: inset + (isOn ? travel : 0))
      }
      .frame(width: size.width, height: size.height)
      .opacity(isEnabled ? 1 : 0.45)
      .animation(AppMenuStyle.liveHighlight, value: isOn)
      .accessibilityHidden(true)
  }
}

/// «Выйти ⌘Q», highlighted like a system menu item.
struct QuitRowView: View {
  let isHighlighted: Bool
  let onQuit: () -> Void
  let onHover: (Bool) -> Void

  var body: some View {
    Button(action: onQuit) {
      HStack {
        Text(AppMenuStrings.quit).font(AppMenuStyle.Fonts.row)
        Spacer()
        Text(AppMenuStrings.quitShortcut)
          .font(AppMenuStyle.Fonts.row)
          .foregroundStyle(isHighlighted ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.tertiary))
      }
      .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
      .padding(AppMenuStyle.rowPadding)
      .background(rowBackground(isHighlighted ? Color.accentColor : .clear, focusRing: false))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .menuControl(onHover: onHover)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(AppMenuStrings.quit)
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { onQuit() }
  }
}

/// The system separator, inset like a menu's.
struct AppMenuSeparator: View {
  var body: some View {
    Rectangle()
      .fill(AppMenuStyle.separator)
      .frame(height: 1)
      .padding(AppMenuStyle.separatorInsets)
      .accessibilityHidden(true)
  }
}

private func card(_ fill: Color) -> some View {
  let shape = RoundedRectangle(cornerRadius: AppMenuStyle.cardCorner, style: .continuous)
  return shape.fill(fill).overlay(shape.strokeBorder(AppMenuStyle.cardEdge, lineWidth: 0.5))
}

private func rowBackground(_ fill: Color, focusRing: Bool) -> some View {
  let shape = RoundedRectangle(cornerRadius: AppMenuStyle.rowCorner, style: .continuous)
  return shape.fill(fill).overlay(shape.strokeBorder(AppMenuStyle.focusRing, lineWidth: 2.5).opacity(focusRing ? 1 : 0))
}
