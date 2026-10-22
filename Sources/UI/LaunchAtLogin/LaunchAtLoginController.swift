import Combine
import Foundation
import InstanceBuilder
import os
import ServiceManagement
import Support

/// The part of `SMAppService` the switch needs; tests substitute a fake (never the real Login Items).
@MainActor public protocol LoginItemService: AnyObject {
  var status: SMAppService.Status { get }
  func register() throws
  func unregister() throws
}

extension SMAppService: LoginItemService {}

/// «Открывать при старте системы» over `SMAppService.mainApp` (R3). The state is re-read from the system on every
/// `refresh()`; nothing is stored besides the last reading. Independent of the menu UI.
@MainActor
public final class LaunchAtLoginController: LaunchAtLoginToggle, ObservableObject {
  @Published public private(set) var state: LaunchAtLoginState = .off
  @Published public private(set) var errorText: String?

  private let service: any LoginItemService
  private let bundleURL: URL
  private let home: URL
  private let openSettings: @MainActor () -> Void
  private let trash: @MainActor (URL) throws -> Void
  private let log = AppLog.logger("launch-at-login")

  /// `bundleURL` is this app's bundle (only `/Applications` and `~/Applications` copies may register); `trash`
  /// moves the old LaunchAgent plist to the Trash; `openSettings` shows System Settings → Login Items.
  public init(
    service: any LoginItemService = SMAppService.mainApp,
    bundleURL: URL = Bundle.main.bundleURL,
    home: URL = Paths.live().home,
    openSettings: @escaping @MainActor () -> Void = { SMAppService.openSystemSettingsLoginItems() },
    trash: @escaping @MainActor (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
  ) {
    self.service = service
    self.bundleURL = bundleURL
    self.home = home
    self.openSettings = openSettings
    self.trash = trash
    refresh()
  }

  /// `SMAppService` status → switch state (`.notFound` is what macOS 15+ reports for a never-registered app).
  public nonisolated static func state(for status: SMAppService.Status) -> LaunchAtLoginState {
    switch status {
    case .enabled: .on
    case .requiresApproval: .needsApproval
    case .notRegistered, .notFound: .off
    @unknown default: .off
    }
  }

  public func refresh() {
    state = currentState()
  }

  public func toggle() {
    switch currentState() {
    case .unavailable: break
    case .needsApproval: openSettings()
    case .on: perform("unregister", failure: LaunchAtLoginText.turnOffFailed) { try service.unregister() }
    case .off: register()
    case .legacyAgent:
      if trashLegacyAgent() { register() }
    }
    refresh()
  }

  // MARK: - Steps

  private var legacyAgentURL: URL { AgentPlist.installURL(kind: .app, home: home) }

  private func currentState() -> LaunchAtLoginState {
    guard Self.isInstalled(bundleURL: bundleURL, home: home) else { return .unavailable }
    if FileManager.default.fileExists(atPath: legacyAgentURL.path) { return .legacyAgent }
    return Self.state(for: service.status)
  }

  /// Registers; when the system wants the user's approval, opens Login Items so they can give it.
  private func register() {
    perform("register", failure: LaunchAtLoginText.turnOnFailed) { try service.register() }
    if service.status == .requiresApproval { openSettings() }
  }

  /// Moves the old `cmacc agent install --kind app` plist to the Trash (never `launchctl`). False on failure.
  private func trashLegacyAgent() -> Bool {
    do {
      try trash(legacyAgentURL)
      return true
    } catch {
      log.error("Cannot trash the old LaunchAgent: \(String(describing: error), privacy: .public)")
      errorText = LaunchAtLoginText.legacyTrashFailed(error.localizedDescription)
      return false
    }
  }

  /// Runs a register/unregister call (`call` names it in the log); «already done» errors are not the user's concern,
  /// others become `errorText` under `failure`.
  private func perform(_ call: String, failure: String, _ action: () throws -> Void) {
    do {
      try action()
      errorText = nil
    } catch {
      if Self.isAlreadyDone(error) {
        errorText = nil
        return
      }
      log.error("SMAppService \(call, privacy: .public) failed: \(String(describing: error), privacy: .public)")
      errorText = "\(failure): \(error.localizedDescription)"
    }
  }

  // MARK: - Rules

  /// `kSMErrorAlreadyRegistered` (12) from register, `kSMErrorJobNotFound` (6) from unregister.
  nonisolated static func isAlreadyDone(_ error: any Error) -> Bool {
    let code = (error as NSError).code
    return code == Int(kSMErrorAlreadyRegistered) || code == Int(kSMErrorJobNotFound)
  }

  /// Only a copy right inside `/Applications` or `~/Applications` may own the login item (R3: the `dist/` copy has
  /// the same bundle id and would record the wrong path).
  nonisolated static func isInstalled(bundleURL: URL, home: URL) -> Bool {
    let parent = bundleURL.standardizedFileURL.deletingLastPathComponent().path
    let allowed = ["/Applications", home.appendingPathComponent("Applications").standardizedFileURL.path]
    return allowed.contains { trimmed($0) == trimmed(parent) }
  }

  private nonisolated static func trimmed(_ path: String) -> String {
    path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
  }
}
