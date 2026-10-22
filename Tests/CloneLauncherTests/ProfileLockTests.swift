import Darwin
import Foundation
import Testing
@testable import CloneLauncher

@Suite struct ProfileLockTests {
  private func tempProfile() -> String {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("cmacc-lock-\(UUID().uuidString)/Profile With Spaces").path
  }

  @Test func createsProfileDirAndLockFile() throws {
    let profile = tempProfile()
    defer { try? FileManager.default.removeItem(atPath: (profile as NSString).deletingLastPathComponent) }
    let fd = try ProfileLock.acquire(profileDir: profile).get()
    defer { close(fd) }
    let attrs = try FileManager.default.attributesOfItem(atPath: profile)
    #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    let lockAttrs = try FileManager.default.attributesOfItem(atPath: profile + "/.clone.lock")
    #expect((lockAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  }

  @Test func descriptorIsNotCloseOnExec() throws {
    let profile = tempProfile()
    defer { try? FileManager.default.removeItem(atPath: (profile as NSString).deletingLastPathComponent) }
    let fd = try ProfileLock.acquire(profileDir: profile).get()
    defer { close(fd) }
    #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC == 0)
  }

  @Test func secondAcquireFailsWithWouldBlockUntilClosed() throws {
    let profile = tempProfile()
    defer { try? FileManager.default.removeItem(atPath: (profile as NSString).deletingLastPathComponent) }
    let first = try ProfileLock.acquire(profileDir: profile).get()
    switch ProfileLock.acquire(profileDir: profile) {
    case .success(let fd):
      close(fd)
      Issue.record("second acquire unexpectedly succeeded")
    case .failure(let error):
      #expect(error == .busy)
    }
    close(first)
    let again = try ProfileLock.acquire(profileDir: profile).get()
    close(again)
  }

  @Test func unwritableParentFails() {
    let result = ProfileLock.acquire(profileDir: "/dev/null/profile")
    if case .failure(let error) = result {
      #expect(error != .busy)
    } else {
      Issue.record("expected failure")
    }
  }
}
