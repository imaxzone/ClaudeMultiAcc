import Darwin
import Foundation

enum LockError: Error, Equatable {
  /// Another process holds the lock (`EWOULDBLOCK`).
  case busy
  case createDirectory
  case open(Int32)
  case flock(Int32)
}

enum ProfileLock {
  /// Exclusive, non-blocking lock on `<profile>/.clone.lock`. The descriptor is deliberately opened without
  /// `O_CLOEXEC` so the lock survives `execv` into Electron and is held for the app's lifetime.
  static func acquire(profileDir: String) -> Result<Int32, LockError> {
    do {
      try FileManager.default.createDirectory(
        atPath: profileDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    } catch {
      return .failure(.createDirectory)
    }
    let fd = open(profileDir + "/.clone.lock", O_RDWR | O_CREAT, 0o600)
    guard fd >= 0 else { return .failure(.open(errno)) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      let code = errno
      close(fd)
      return .failure(code == EWOULDBLOCK ? .busy : .flock(code))
    }
    return .success(fd)
  }
}
