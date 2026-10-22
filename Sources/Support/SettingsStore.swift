import Foundation

public enum SettingsStoreError: Error, Equatable {
  /// `settings.json` exists but cannot be decoded; `underlying` is the decoding error description.
  case corrupt(path: String, underlying: String)
}

/// Serialises reads and atomic writes of `settings.json`. A corrupt file is never overwritten.
public actor SettingsStore {
  private let file: URL
  private let clock: any Clock
  private let log = AppLog.logger("settings")

  public init(file: URL, clock: any Clock = SystemClock()) {
    self.file = file
    self.clock = clock
  }

  /// Lenient read for display: `defaults` when the file is missing or unreadable.
  public func load() -> AppSettings {
    do {
      return try loadStrict()
    } catch {
      log.error("Failed to read settings, using defaults: \(String(describing: error), privacy: .public)")
      return .defaults
    }
  }

  /// Strict read: `defaults` when the file is missing, `SettingsStoreError.corrupt` when it cannot be decoded.
  public func loadStrict() throws -> AppSettings {
    guard FileManager.default.fileExists(atPath: file.path) else { return .defaults }
    do {
      return try JSONCoding.decoder.decode(AppSettings.self, from: Data(contentsOf: file))
    } catch {
      throw SettingsStoreError.corrupt(path: file.path, underlying: String(describing: error))
    }
  }

  /// Applies `transform` to the current settings, persists the result atomically and returns it.
  /// On a corrupt file it copies the file aside (`settings.json.corrupt-<yyyyMMdd-HHmmss>`) and throws without writing.
  @discardableResult
  public func update(_ transform: @Sendable (AppSettings) -> AppSettings) throws -> AppSettings {
    let current: AppSettings
    do {
      current = try loadStrict()
    } catch {
      preserveCorruptFile()
      throw error
    }
    let updated = transform(current)
    let data = try JSONCoding.encoder.encode(updated)
    try AtomicFile.write(data, to: file, permissions: 0o600)
    return updated
  }

  private func preserveCorruptFile() {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let aside = URL(fileURLWithPath: file.path + ".corrupt-\(formatter.string(from: clock.now))")
    do {
      if !FileManager.default.fileExists(atPath: aside.path) {
        try FileManager.default.copyItem(at: file, to: aside)
      }
      log.error("Refusing to overwrite corrupt settings; copy kept at \(aside.lastPathComponent, privacy: .public)")
    } catch {
      log.error("Refusing to overwrite corrupt settings; copy failed: \(String(describing: error), privacy: .public)")
    }
  }
}
