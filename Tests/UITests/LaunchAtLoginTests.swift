import Foundation
import ServiceManagement
import Testing
@testable import UI

/// Ordered record of what the fakes saw, so tests can check «trash, then register».
@MainActor
final class LoginEventLog {
  private(set) var events: [String] = []
  func add(_ event: String) { events.append(event) }
}

/// `SMAppService.mainApp` stand-in: scripted status and errors, never touches Login Items.
@MainActor
final class FakeLoginItemService: LoginItemService {
  var status: SMAppService.Status
  var registerError: (any Error)?
  var unregisterError: (any Error)?
  var statusAfterRegister: SMAppService.Status = .enabled
  var statusAfterUnregister: SMAppService.Status = .notRegistered
  private let log: LoginEventLog

  init(_ status: SMAppService.Status, log: LoginEventLog = LoginEventLog()) {
    self.status = status
    self.log = log
  }

  var calls: [String] { log.events.filter { ["register", "unregister"].contains($0) } }

  func register() throws {
    log.add("register")
    status = statusAfterRegister
    if let registerError { throw registerError }
  }

  func unregister() throws {
    log.add("unregister")
    status = statusAfterUnregister
    if let unregisterError { throw unregisterError }
  }
}

@MainActor
@Suite(.russian) struct LaunchAtLoginControllerTests {
  @MainActor struct Fixture {
    let home: URL
    let log: LoginEventLog
    let service: FakeLoginItemService
    let controller: LaunchAtLoginController
    var legacyPlist: URL { home.appendingPathComponent("Library/LaunchAgents/com.imaxzone.ClaudeMultiAcc.plist") }
    var settingsOpened: Int { log.events.filter { $0 == "settings" }.count }
  }

  /// A temp home with the app in `~/Applications` unless `bundle` says otherwise; trash moves into `<home>/.Trash`.
  private func fixture(
    _ status: SMAppService.Status, bundle: ((URL) -> URL)? = nil, legacy: Bool = false, trashFails: Bool = false,
    name: String = #function
  ) throws -> Fixture {
    let home = try makeTempDir(name)
    let log = LoginEventLog()
    let service = FakeLoginItemService(status, log: log)
    let bundleURL = bundle?(home) ?? home.appendingPathComponent("Applications/ClaudeMultiAcc.app", isDirectory: true)
    let plist = home.appendingPathComponent("Library/LaunchAgents/com.imaxzone.ClaudeMultiAcc.plist")
    if legacy {
      try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("<plist/>".utf8).write(to: plist)
    }
    let trashDir = home.appendingPathComponent(".Trash", isDirectory: true)
    let controller = LaunchAtLoginController(
      service: service, bundleURL: bundleURL, home: home,
      openSettings: { log.add("settings") },
      trash: { url in
        log.add("trash:\(url.lastPathComponent)")
        if trashFails { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: trashDir.appendingPathComponent(url.lastPathComponent))
      })
    return Fixture(home: home, log: log, service: service, controller: controller)
  }

  private static func smError(_ code: Int) -> NSError {
    NSError(domain: SMAppServiceErrorDomain, code: code, userInfo: [NSLocalizedDescriptionKey: "code \(code)"])
  }

  @Test(arguments: [
    (SMAppService.Status.enabled, LaunchAtLoginState.on),
    (.notRegistered, .off),
    (.notFound, .off),
    (.requiresApproval, .needsApproval),
  ])
  func mapsTheServiceStatus(status: SMAppService.Status, expected: LaunchAtLoginState) throws {
    #expect(LaunchAtLoginController.state(for: status) == expected)
    let f = try fixture(status)
    #expect(f.controller.state == expected)
    #expect(f.controller.errorText == nil)
  }

  @Test func refreshReReadsTheStatusEveryTime() throws {
    let f = try fixture(.notFound)
    #expect(f.controller.state == .off)
    f.service.status = .enabled
    #expect(f.controller.state == .off)
    f.controller.refresh()
    #expect(f.controller.state == .on)
    f.service.status = .requiresApproval
    f.controller.refresh()
    #expect(f.controller.state == .needsApproval)
  }

  @Test func switchingOnRegisters() throws {
    let f = try fixture(.notRegistered)
    f.controller.toggle()
    #expect(f.service.calls == ["register"])
    #expect(f.controller.state == .on)
    #expect(f.controller.errorText == nil)
    #expect(f.settingsOpened == 0)
  }

  @Test func switchingOffUnregisters() throws {
    let f = try fixture(.enabled)
    f.controller.toggle()
    #expect(f.service.calls == ["unregister"])
    #expect(f.controller.state == .off)
    #expect(f.controller.errorText == nil)
  }

  @Test func registeringIntoApprovalOpensLoginItemsOnce() throws {
    let f = try fixture(.notFound)
    f.service.statusAfterRegister = .requiresApproval
    f.controller.toggle()
    #expect(f.service.calls == ["register"])
    #expect(f.controller.state == .needsApproval)
    #expect(f.settingsOpened == 1)
    #expect(f.controller.errorText == nil)
  }

  @Test func clickingWhileAwaitingApprovalOnlyOpensLoginItems() throws {
    let f = try fixture(.requiresApproval)
    f.controller.toggle()
    #expect(f.service.calls.isEmpty)
    #expect(f.settingsOpened == 1)
    #expect(f.controller.state == .needsApproval)
  }

  /// `AlreadyRegistered` (12) on register and `JobNotFound` (6) on unregister are not errors for the user.
  @Test(arguments: [(SMAppService.Status.notRegistered, 12), (.enabled, 6)])
  func ignoresAlreadyDoneErrors(start: SMAppService.Status, code: Int) throws {
    let f = try fixture(start)
    f.service.registerError = Self.smError(code)
    f.service.unregisterError = Self.smError(code)
    f.controller.toggle()
    #expect(f.service.calls.count == 1)
    #expect(f.controller.errorText == nil)
  }

  @Test func otherErrorsAreShownAndTheStatusIsReRead() throws {
    let f = try fixture(.notRegistered)
    f.service.registerError = Self.smError(3)
    f.service.statusAfterRegister = .enabled
    f.controller.toggle()
    let text = try #require(f.controller.errorText)
    #expect(text.contains("code 3"))
    #expect(f.controller.state == .on)
    #expect(f.controller.subtitle == text)
  }

  @Test func aSuccessfulToggleClearsTheLastError() throws {
    let f = try fixture(.notRegistered)
    f.service.registerError = Self.smError(3)
    f.service.statusAfterRegister = .notRegistered
    f.controller.toggle()
    #expect(f.controller.errorText != nil)
    f.service.registerError = nil
    f.service.statusAfterRegister = .enabled
    f.controller.toggle()
    #expect(f.controller.errorText == nil)
    #expect(f.controller.state == .on)
  }

  @Test(arguments: [
    "/Users/u/Downloads/ClaudeMultiAcc.app",
    "/Users/u/Documents/GitHub/ClaudeMultiAcc/dist/ClaudeMultiAcc.app",
    "/Applications/Utilities/ClaudeMultiAcc.app",
    "/Users/u/Documents/GitHub/ClaudeMultiAcc/.build/debug",
  ])
  func outsideApplicationsTheSwitchIsUnavailable(path: String) throws {
    let f = try fixture(.notRegistered, bundle: { _ in URL(fileURLWithPath: path, isDirectory: true) })
    #expect(f.controller.state == .unavailable)
    f.controller.toggle()
    #expect(f.service.calls.isEmpty)
    #expect(f.settingsOpened == 0)
    #expect(f.controller.state == .unavailable)
  }

  @Test func systemApplicationsCountsAsInstalled() throws {
    let f = try fixture(.enabled, bundle: { _ in URL(fileURLWithPath: "/Applications/ClaudeMultiAcc.app", isDirectory: true) })
    #expect(f.controller.state == .on)
  }

  @Test func anOldLaunchAgentShowsAsLegacy() throws {
    let f = try fixture(.notFound, legacy: true)
    #expect(f.controller.state == .legacyAgent)
  }

  @Test func togglingFromLegacyTrashesThePlistThenRegisters() throws {
    let f = try fixture(.notFound, legacy: true)
    f.controller.toggle()
    #expect(f.log.events == ["trash:com.imaxzone.ClaudeMultiAcc.plist", "register"])
    #expect(!FileManager.default.fileExists(atPath: f.legacyPlist.path))
    #expect(FileManager.default.fileExists(atPath: f.home.appendingPathComponent(".Trash/com.imaxzone.ClaudeMultiAcc.plist").path))
    #expect(f.controller.state == .on)
    #expect(f.controller.errorText == nil)
  }

  @Test func whenTheOldPlistCannotBeTrashedNothingIsRegistered() throws {
    let f = try fixture(.notFound, legacy: true, trashFails: true)
    f.controller.toggle()
    #expect(f.service.calls.isEmpty)
    #expect(f.controller.state == .legacyAgent)
    #expect(f.controller.errorText != nil)
  }

  @Test func subtitlesExplainEveryNonPlainState() throws {
    #expect(LaunchAtLoginState.on.subtitle == nil)
    #expect(LaunchAtLoginState.off.subtitle == nil)
    #expect(LaunchAtLoginState.needsApproval.subtitle == "Разрешите в Системных настройках")
    #expect(LaunchAtLoginState.legacyAgent.subtitle == "Сейчас через LaunchAgent — нажмите, чтобы перейти")
    #expect(LaunchAtLoginState.unavailable.subtitle == "Доступно после установки в Программы")
    let f = try fixture(.requiresApproval)
    #expect(f.controller.subtitle == "Разрешите в Системных настройках")
  }

  @Test func switchPositionAndAvailability() {
    #expect(LaunchAtLoginState.on.isOn && LaunchAtLoginState.legacyAgent.isOn)
    #expect(!LaunchAtLoginState.off.isOn && !LaunchAtLoginState.needsApproval.isOn && !LaunchAtLoginState.unavailable.isOn)
    #expect(!LaunchAtLoginState.unavailable.isAvailable)
    let available = [LaunchAtLoginState.on, .off, .needsApproval, .legacyAgent].filter(\.isAvailable)
    #expect(available.count == 4)
  }
}

@Suite(.russian) struct SingleInstanceTests {
  static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

  private func copy(_ pid: Int32, _ offset: TimeInterval?) -> RunningInstance {
    RunningInstance(pid: pid, launchDate: offset.map { Self.t0.addingTimeInterval($0) })
  }

  @Test func aloneKeepsRunning() {
    #expect(SingleInstance.olderCopy(own: copy(10, 0), running: []) == nil)
    #expect(SingleInstance.olderCopy(own: copy(10, 0), running: [copy(10, 0)]) == nil)
  }

  @Test func theLaterLaunchYieldsToTheOlderCopy() {
    let older = copy(20, -60)
    #expect(SingleInstance.olderCopy(own: copy(10, 0), running: [copy(10, 0), older]) == older)
  }

  @Test func theOlderCopyKeepsRunning() {
    #expect(SingleInstance.olderCopy(own: copy(10, 0), running: [copy(10, 0), copy(20, 60)]) == nil)
  }

  @Test func equalLaunchDatesFallBackToTheLowerPid() {
    #expect(SingleInstance.olderCopy(own: copy(30, 0), running: [copy(20, 0)]) == copy(20, 0))
    #expect(SingleInstance.olderCopy(own: copy(20, 0), running: [copy(30, 0)]) == nil)
  }

  /// Unknown launch dates sort last, so both copies agree on one survivor.
  @Test func unknownLaunchDatesCountAsLatest() {
    #expect(SingleInstance.olderCopy(own: copy(10, 0), running: [copy(20, nil)]) == nil)
    #expect(SingleInstance.olderCopy(own: copy(20, nil), running: [copy(10, 0)]) == copy(10, 0))
  }

  @Test func yieldsToTheOldestOfSeveral() {
    let oldest = copy(5, -120)
    #expect(SingleInstance.olderCopy(own: copy(10, 0), running: [copy(7, -60), oldest, copy(10, 0)]) == oldest)
  }
}
