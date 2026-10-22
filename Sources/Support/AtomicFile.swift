import Foundation

public enum AtomicFileError: Error, Equatable {
  case createTemp(path: String, errno: Int32)
  case write(path: String, errno: Int32)
  case rename(path: String, errno: Int32)
}

/// Crash-safe file replacement: write a temp file in the same directory, fsync, then rename(2).
public enum AtomicFile {
  public static func write(_ data: Data, to url: URL, permissions: Int16 = 0o644) throws {
    let dir = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let temp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
    let mode = mode_t(UInt16(bitPattern: permissions))
    let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
    guard fd >= 0 else { throw AtomicFileError.createTemp(path: temp.path, errno: errno) }
    do {
      try writeAll(data, fd: fd, path: temp.path, mode: mode)
      close(fd)
    } catch {
      close(fd)
      unlink(temp.path)
      throw error
    }
    guard rename(temp.path, url.path) == 0 else {
      let code = errno
      unlink(temp.path)
      throw AtomicFileError.rename(path: url.path, errno: code)
    }
  }

  private static func writeAll(_ data: Data, fd: Int32, path: String, mode: mode_t) throws {
    // fchmod bypasses the process umask so the requested mode is exact.
    guard fchmod(fd, mode) == 0 else { throw AtomicFileError.write(path: path, errno: errno) }
    try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
      guard let base = buffer.baseAddress else { return }
      var offset = 0
      while offset < buffer.count {
        let written = Foundation.write(fd, base + offset, buffer.count - offset)
        if written < 0 {
          if errno == EINTR { continue }
          throw AtomicFileError.write(path: path, errno: errno)
        }
        offset += written
      }
    }
    guard fsync(fd) == 0 else { throw AtomicFileError.write(path: path, errno: errno) }
  }
}
