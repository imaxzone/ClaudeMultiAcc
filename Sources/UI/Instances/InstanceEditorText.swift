import Foundation

/// Every string of the «Добавить» / «Изменить…» window and its install question, in the UI language.
enum InstanceEditorText {
  // MARK: Window

  static var addTitle: String { UIText.string("editor.title.add") }
  static func editTitle(name: String) -> String { UIText.format("editor.title.edit", name) }
  static var editTitlePlain: String { UIText.string("editor.title.edit-plain") }
  static var create: String { UIText.string("editor.submit.create") }
  static var save: String { UIText.string("editor.submit.save") }
  static var reinstall: String { UIText.string("editor.submit.reinstall") }
  static var cancel: String { UIText.string("common.cancel") }
  static var done: String { UIText.string("editor.button.done") }
  static var close: String { UIText.string("editor.button.close") }

  // MARK: Fields and preview

  static var nameTitle: String { UIText.string("editor.field.name") }
  static var namePrompt: String { UIText.string("editor.field.name-prompt") }
  static var nameHint: String { UIText.string("editor.field.name-hint") }
  static var badgeTitle: String { UIText.string("editor.field.badge") }
  static var badgePrompt: String { UIText.string("editor.field.badge-prompt") }
  static var badgeHint: String { UIText.string("editor.field.badge-hint") }
  static var untitled: String { UIText.string("editor.preview.untitled") }
  /// VoiceOver: «Иконка «Claude Работа» с надписью Раб».
  static func iconLabel(name: String, badge: String) -> String {
    badge.isEmpty
      ? UIText.format("editor.preview.icon", name) : UIText.format("editor.preview.icon-label", name, badge)
  }

  // MARK: A name used before

  static func leftoverTitle(name: String) -> String { UIText.format("editor.leftover.title", name) }
  static var leftoverQuestion: String { UIText.string("editor.leftover.question") }
  static var leftoverSignIn: String { UIText.string("editor.leftover.sign-in") }
  static var leftoverStartFresh: String { UIText.string("editor.leftover.start-fresh") }

  // MARK: The line above the buttons

  static func addNote(signedIn: Bool) -> String {
    UIText.string(signedIn ? "editor.note.add-signed-in" : "editor.note.add")
  }
  static func closingNote(name: String) -> String { UIText.format("editor.note.closing", name) }
  static var rebuildNote: String { UIText.string("editor.note.rebuild") }
  static var signedInNote: String { UIText.string("editor.note.signed-in") }
  static var dockNote: String { UIText.string("editor.note.dock") }
  static func reinstallNote(name: String) -> String { UIText.format("editor.note.reinstall", name) }

  // MARK: Progress and outcome

  static var signing: String { UIText.string("editor.progress.signing") }
  static func building(_ name: String, rebuild: Bool) -> String {
    UIText.format(rebuild ? "editor.progress.rebuilding" : "editor.progress.building", name)
  }
  static func reinstalling(_ name: String) -> String { UIText.format("editor.progress.reinstalling", name) }
  static var confirming: String { UIText.string("editor.progress.confirming") }
  static var installing: String { UIText.string("editor.progress.installing") }
  static func opening(_ name: String) -> String { UIText.format("editor.progress.opening", name) }
  static func closing(_ name: String) -> String { UIText.format("editor.progress.closing", name) }
  static func reopening(_ name: String) -> String { UIText.format("editor.progress.reopening", name) }
  static var createFailed: String { UIText.string("editor.failure.create") }
  static var saveFailed: String { UIText.string("editor.failure.save") }
  static var reinstallFailed: String { UIText.string("editor.failure.reinstall") }
  static var noSigning: String { UIText.string("editor.no-signing") }
  static var loadFailed: String { UIText.string("editor.load-failed") }
  static func notVerified(step: String) -> String { UIText.format("editor.not-verified-at", step) }
  static var leftoverTrashFailed: String { UIText.string("editor.leftover-trash-failed") }
  static func created(_ name: String) -> String { UIText.format("editor.done.created", name) }
  static var saved: String { UIText.string("editor.done.saved") }
  static var reinstalled: String { UIText.string("editor.done.reinstalled") }
  static func reopened(_ name: String) -> String { UIText.format("editor.done.reopened", name) }

  // MARK: Dock refresh on the done screen

  static var refreshDock: String { UIText.string("editor.dock.refresh") }
  static var dockRefreshed: String { UIText.string("editor.dock.refreshed") }
  static var dockRefreshNote: String { UIText.string("editor.dock.note") }
  static var dockRefreshFailed: String { UIText.string("editor.dock.failed") }

  /// The detail under «“Claude Work” is ready».
  static func createdDetail(opened: Bool, signedIn: Bool) -> String {
    switch (opened, signedIn) {
    case (true, true): UIText.string("editor.created.opened-signed-in")
    case (true, false): UIText.string("editor.created.opened")
    case (false, true): UIText.string("editor.created.signed-in")
    case (false, false): UIText.string("editor.created")
    }
  }

  // MARK: Install question

  static func installTitle(name: String) -> String { UIText.format("install.title", name) }
  static var installText: String { UIText.string("install.text") }
  static var install: String { UIText.string("install.install") }
}
