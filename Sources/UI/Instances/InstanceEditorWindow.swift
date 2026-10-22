import AppKit
import InstanceBuilder
import Support
import SwiftUI

/// The «Изменить…» / «Добавить» window: one per mode (a second «Изменить…» of the same app brings its window
/// forward unless its work is over, then a fresh one opens). It cannot be closed while a build or install runs.
@MainActor
public final class InstanceEditorWindowController: NSObject, NSWindowDelegate {
  public static let width: CGFloat = 440

  private let makeModel: @MainActor (InstanceEditorMode) -> InstanceEditorViewModel
  private var windows: [InstanceEditorMode: (window: NSWindow, model: InstanceEditorViewModel)] = [:]

  public init(makeModel: @escaping @MainActor (InstanceEditorMode) -> InstanceEditorViewModel) {
    self.makeModel = makeModel
  }

  /// The live window: real services and alerts. `ensureSigning` runs before every build and returns the permanent
  /// identity (default: today's read-only check, which never creates one); `quitter` / `opener` close and reopen a
  /// running clone around «Сохранить» / «Переустановить» (default: polite quit, background open); `refreshDock` runs
  /// when «Обновить Док» is clicked on the done screen with the edited clone's app (default:
  /// `InstanceEditorDock.restart`, staged bundles refused); `onChange` runs after a successful add or edit with the new
  /// `instances.json` entry.
  public convenience init(
    paths: Paths, launcherBinary: URL, ensureSigning: InstanceEditorEnsureSigning? = nil,
    quitter: (any AppQuitting)? = nil, opener: (any AppOpening)? = nil, refreshDock: InstanceEditorRefreshDock? = nil,
    onChange: @escaping @MainActor (Instance) -> Void = { _ in }
  ) {
    let services = LiveInstanceEditorServices(
      paths: paths, launcherBinary: launcherBinary, quitter: quitter, opener: opener)
    let signing = ensureSigning ?? InstanceEditorSigning.identityCheck(paths: paths)
    let dock = refreshDock ?? InstanceEditorDock.restart(staging: StagingArea(paths: paths))
    let dialogs = AlertInstanceEditorDialogs()
    self.init { mode in
      let model = InstanceEditorViewModel(
        mode: mode, services: services, dialogs: dialogs, ensureSigning: signing, refreshDock: dock)
      model.onFinish = onChange
      return model
    }
  }

  public func showAdd() {
    show(.add)
  }

  public func showEdit(slug: String) {
    show(.edit(slug: slug))
  }

  func show(_ mode: InstanceEditorMode) {
    let window = window(for: mode)
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
  }

  /// The open window of `mode`, or a new one; a window whose work is over (done, or nothing to edit) is replaced.
  func window(for mode: InstanceEditorMode) -> NSWindow {
    if let open = windows[mode] {
      switch open.model.phase {
      case .done, .unavailable:
        windows[mode] = nil
        open.window.close()
      default:
        return open.window
      }
    }
    return makeWindow(mode)
  }

  func makeWindow(_ mode: InstanceEditorMode) -> NSWindow {
    let model = makeModel(mode)
    let host = NSHostingController(rootView: InstanceEditorView(model: model) { [weak self] in
      self?.windows[mode]?.window.close()
    })
    host.sizingOptions = [.preferredContentSize]
    let window = NSWindow(contentViewController: host)
    window.setContentSize(host.view.fittingSize)
    window.title = model.windowTitle
    window.styleMask = [.titled, .closable]
    window.isReleasedWhenClosed = false
    window.center()
    window.delegate = self
    windows[mode] = (window, model)
    let finished = model.onFinish
    model.onFinish = { [weak window, weak model] instance in
      window?.title = model?.windowTitle ?? ""
      finished?(instance)
    }
    Task { [weak window] in
      await model.load()
      window?.title = model.windowTitle
    }
    return window
  }

  public func windowShouldClose(_ sender: NSWindow) -> Bool {
    !(windows.values.first { $0.window === sender }?.model.isBusy ?? false)
  }

  public func windowWillClose(_ notification: Notification) {
    guard let closing = notification.object as? NSWindow else { return }
    windows = windows.filter { $0.value.window !== closing }
  }
}

/// Left: the live icon (official icon + label) and the name under it; right: «Название» and «Надпись на иконке».
struct InstanceEditorView: View {
  @ObservedObject var model: InstanceEditorViewModel
  let close: () -> Void
  @FocusState private var focused: InstanceEditorField?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: 20) {
        InstanceEditorPreview(name: model.previewName, badge: model.previewBadge)
        fields
      }
      .padding(.horizontal, 22)
      .padding(.top, 18)
      .padding(.bottom, 10)
      footer
        .padding(.horizontal, 22)
      buttons
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
    }
    .frame(width: InstanceEditorWindowController.width)
    .onAppear { focused = .name }
  }

  private var fields: some View {
    VStack(alignment: .leading, spacing: 12) {
      field(InstanceEditorText.nameTitle, text: $model.name, prompt: InstanceEditorText.namePrompt, focus: .name,
            hint: InstanceEditorText.nameHint)
      field(InstanceEditorText.badgeTitle, text: $model.badge, prompt: InstanceEditorText.badgePrompt, focus: .badge,
            hint: InstanceEditorText.badgeHint)
    }
    .padding(.top, 6)
    .disabled(model.fieldsLocked)
  }

  private func field(
    _ title: String, text: Binding<String>, prompt: String, focus: InstanceEditorField, hint: String
  ) -> some View {
    let messages = model.messages(for: focus)
    return VStack(alignment: .leading, spacing: 3) {
      Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
      TextField(title, text: text, prompt: Text(prompt))
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
        .focused($focused, equals: focus)
      if messages.isEmpty {
        Text(hint).font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
      } else {
        ForEach(messages, id: \.self) { ValidationText($0) }
      }
    }
  }

  @ViewBuilder private var footer: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(model.messages(for: .general), id: \.self) { ValidationText($0) }
      if let appName = model.leftoverFor, !model.fieldsLocked {
        LeftoverProfileQuestion(appName: appName, choice: $model.leftoverChoice)
          .padding(.bottom, 4)
      }
      switch model.phase {
      case .loading:
        EmptyView()
      case .editing:
        if let note = model.note {
          Text(note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      case .working:
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text(model.progressText ?? "").font(.system(size: 12)).foregroundStyle(.secondary)
        }
      case .failed(let message):
        EditorStatus(symbol: "xmark.octagon.fill", color: .systemRed, title: model.failureTitle, detail: message)
      case .done(let title, let detail):
        EditorStatus(
          symbol: "checkmark.circle.fill", color: .systemGreen, title: title, detail: detail,
          note: model.offersDockRefresh ? model.dockNote : nil, noteIsError: model.dockRefresh == .failed)
      case .unavailable(let message):
        EditorStatus(symbol: "exclamationmark.triangle.fill", color: .systemOrange, title: message, detail: nil)
      }
    }
  }

  private var buttons: some View {
    HStack(spacing: 8) {
      Spacer()
      switch model.phase {
      case .done:
        if model.offersDockRefresh {
          Button(model.dockButtonTitle) { Task { await model.refreshDock() } }
            .disabled(!model.canRefreshDock)
        }
        Button(InstanceEditorText.done, action: close).keyboardShortcut(.defaultAction)
      case .unavailable:
        Button(InstanceEditorText.close, action: close).keyboardShortcut(.defaultAction)
      default:
        Button(InstanceEditorText.cancel, action: close).keyboardShortcut(.cancelAction).disabled(model.isBusy)
        Button(model.submitTitle) { Task { await model.submit() } }
          .keyboardShortcut(.defaultAction)
          .disabled(!model.canSubmit)
      }
    }
  }
}

/// The badged official icon at 112 pt, redrawn on every keystroke of the label.
struct InstanceEditorPreview: View {
  static let side: CGFloat = 112
  let name: String?
  let badge: String

  var body: some View {
    VStack(spacing: 6) {
      icon
        .frame(width: Self.side, height: Self.side)
        .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
      Text(name ?? InstanceEditorText.untitled)
        .font(.system(size: 12, weight: name == nil ? .regular : .medium))
        .foregroundStyle(name == nil ? .tertiary : .primary)
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .frame(width: Self.side + 8)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(InstanceEditorText.iconLabel(name: name ?? "", badge: badge))
  }

  @ViewBuilder private var icon: some View {
    if let image = BadgePreview.image(label: badge) {
      Image(nsImage: image).resizable().interpolation(.high)
    } else {
      RoundedRectangle(cornerRadius: 25, style: .continuous).fill(.quaternary)
    }
  }
}

/// «Добавить» of a name used before: keep the sign-in and settings the removed app left, or start clean.
private struct LeftoverProfileQuestion: View {
  let appName: String
  @Binding var choice: LeftoverProfileChoice

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "person.crop.circle.badge.clock")
        .foregroundStyle(Color.accentColor)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 6) {
        Text(InstanceEditorText.leftoverTitle(name: appName))
          .font(.system(size: 13, weight: .semibold))
          .fixedSize(horizontal: false, vertical: true)
        Picker(InstanceEditorText.leftoverQuestion, selection: $choice) {
          Text(InstanceEditorText.leftoverSignIn).tag(LeftoverProfileChoice.signInAsBefore)
          Text(InstanceEditorText.leftoverStartFresh).tag(LeftoverProfileChoice.startClean)
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
        .font(.system(size: 12))
      }
    }
  }
}

/// A coloured symbol with a bold line, an optional detail and an optional 11 pt note under it (the done screen: why
/// «Обновить Док» helps, or, red, that it failed).
private struct EditorStatus: View {
  let symbol: String
  let color: NSColor
  let title: String
  let detail: String?
  var note: String?
  var noteIsError = false

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: symbol).foregroundStyle(Color(nsColor: color)).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
        if let detail {
          Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if let note {
          Text(note)
            .font(.system(size: 11))
            .foregroundStyle(noteIsError ? AnyShapeStyle(Color(nsColor: .systemRed)) : AnyShapeStyle(.secondary))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
        }
      }
    }
    .accessibilityElement(children: .combine)
  }
}

/// 11 pt red message under a field.
struct ValidationText: View {
  let text: String

  init(_ text: String) {
    self.text = text
  }

  var body: some View {
    Label(text, systemImage: "exclamationmark.circle.fill")
      .font(.system(size: 11))
      .foregroundStyle(Color(nsColor: .systemRed))
      .fixedSize(horizontal: false, vertical: true)
  }
}
