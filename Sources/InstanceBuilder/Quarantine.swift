import Foundation

public enum QuarantineError: Error, Equatable {
  case removeFailed(path: String, errno: Int32)

  public var userMessage: String { BuilderText.string("quarantine.remove-failed") }
}

/// `com.apple.quarantine` hygiene for anything copied from a downloaded ClaudeMultiAcc.app into a clone after the
/// `clean` step (R2 item 4): copies keep extended attributes, and a quarantined file inside a locally signed clone
/// makes Gatekeeper refuse it. Symlinks are never followed.
public enum Quarantine {
  public static let attribute = "com.apple.quarantine"

  public static func isSet(on url: URL) -> Bool {
    getxattr(url.path, attribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0
  }

  /// Removes the attribute from `url` and, for a directory, from everything inside it; a missing attribute is fine.
  public static func remove(from url: URL) throws {
    try removeOne(url.path)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
          let entries = FileManager.default.enumerator(atPath: url.path) else { return }
    while let relative = entries.nextObject() as? String {
      try removeOne(url.appendingPathComponent(relative).path)
    }
  }

  private static func removeOne(_ path: String) throws {
    guard removexattr(path, attribute, XATTR_NOFOLLOW) != 0 else { return }
    let code = errno
    guard code != ENOATTR else { return }
    throw QuarantineError.removeFailed(path: path, errno: code)
  }
}
