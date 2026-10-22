import Foundation

/// The renames a swap, rollback or install performs; injectable so tests can fail a chosen step.
public struct FileMover: Sendable {
  public let move: @Sendable (URL, URL) throws -> Void

  public init(move: @escaping @Sendable (URL, URL) throws -> Void) {
    self.move = move
  }

  public static let live = FileMover { try FileManager.default.moveItem(at: $0, to: $1) }

  static let disabledPlist = "Info.plist.disabled"

  /// `Contents/Info.plist` → `Contents/Info.plist.disabled`, so LaunchServices ignores the bundle.
  func disablePlist(in app: URL) throws {
    let contents = app.appendingPathComponent("Contents")
    try move(contents.appendingPathComponent("Info.plist"), contents.appendingPathComponent(Self.disabledPlist))
  }

  func enablePlist(in app: URL) throws {
    let contents = app.appendingPathComponent("Contents")
    try move(contents.appendingPathComponent(Self.disabledPlist), contents.appendingPathComponent("Info.plist"))
  }
}

/// Runs one undo step; returns the error (after logging it) instead of swallowing it.
func attemptUndo(_ what: String, log: (String) -> Void, _ body: () throws -> Void) -> (any Error)? {
  do {
    try body()
    return nil
  } catch {
    log("undo step '\(what)' failed: \(error)")
    return error
  }
}
