import Foundation

/// A child started with posix_spawn as the leader of a new process group, with piped stdout/stderr
/// and either a stdin pipe or /dev/null. All other descriptors are closed in the child.
struct SpawnedProcess: Sendable {
  let pid: pid_t
  let stdoutFD: Int32
  let stderrFD: Int32
  /// Write end of the stdin pipe, when `request.stdin` is set.
  let stdinFD: Int32?

  static func spawn(_ request: ProcessRequest) throws -> SpawnedProcess {
    // Every descriptor is owned from the moment it exists: child ends are always closed here,
    // parent ends are closed on any failure before they are handed to the returned value.
    var childEnds: [Int32] = []
    var parentEnds: [Int32] = []
    defer { childEnds.forEach { close($0) } }
    do {
      let out = try makePipe(request)
      childEnds.append(out.write)
      parentEnds.append(out.read)
      let err = try makePipe(request)
      childEnds.append(err.write)
      parentEnds.append(err.read)
      let stdin = try openStdin(request)
      childEnds.append(stdin.child)
      if let parent = stdin.parent { parentEnds.append(parent) }

      let pid = try launch(request, stdin: stdin.child, stdout: out.write, stderr: err.write)
      return SpawnedProcess(pid: pid, stdoutFD: out.read, stderrFD: err.read, stdinFD: stdin.parent)
    } catch {
      parentEnds.forEach { close($0) }
      throw error
    }
  }

  /// Child stdin: the read end of a pipe (parent keeps the write end) or /dev/null.
  private static func openStdin(_ request: ProcessRequest) throws -> (child: Int32, parent: Int32?) {
    if request.stdin != nil {
      let pipe = try makePipe(request)
      return (pipe.read, pipe.write)
    }
    let devNull = open("/dev/null", O_RDONLY | O_CLOEXEC)
    guard devNull >= 0 else { throw launchError(request, errno) }
    return (devNull, nil)
  }

  /// Blocks until the child exits; returns its exit status, or 128 + signal.
  func waitForExit() -> Int32 {
    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1, errno == EINTR {}
    let signal = status & 0x7f
    return signal == 0 ? (status >> 8) & 0xff : 128 + signal
  }

  private static func configure(_ attrs: inout posix_spawnattr_t?) {
    var noSignals = sigset_t()
    var defaultSignals: sigset_t = 1 << (UInt32(SIGPIPE) - 1)
    posix_spawnattr_setsigmask(&attrs, &noSignals)
    posix_spawnattr_setsigdefault(&attrs, &defaultSignals)
    posix_spawnattr_setpgroup(&attrs, 0)
    let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
    posix_spawnattr_setflags(&attrs, Int16(flags))
  }

  private static func launch(
    _ request: ProcessRequest, stdin: Int32, stdout: Int32, stderr: Int32
  ) throws -> pid_t {
    var actions: posix_spawn_file_actions_t?
    var attrs: posix_spawnattr_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawnattr_init(&attrs)
    defer {
      posix_spawn_file_actions_destroy(&actions)
      posix_spawnattr_destroy(&attrs)
    }
    posix_spawn_file_actions_adddup2(&actions, stdin, STDIN_FILENO)
    posix_spawn_file_actions_adddup2(&actions, stdout, STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&actions, stderr, STDERR_FILENO)
    if let cwd = request.currentDirectory {
      posix_spawn_file_actions_addchdir(&actions, cwd.path)
    }
    configure(&attrs)

    let environment = request.environment ?? ProcessInfo.processInfo.environment
    let argv = ([request.executable.path] + request.arguments).map { strdup($0) } + [nil]
    let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { (argv + envp).forEach { free($0) } }
    var pid: pid_t = 0
    let result = posix_spawn(&pid, request.executable.path, &actions, &attrs, argv, envp)
    guard result == 0 else { throw launchError(request, result) }
    return pid
  }

  private static func makePipe(_ request: ProcessRequest) throws -> (read: Int32, write: Int32) {
    var fds: [Int32] = [-1, -1]
    guard pipe(&fds) == 0 else { throw launchError(request, errno) }
    fds.forEach { _ = fcntl($0, F_SETFD, FD_CLOEXEC) }
    return (fds[0], fds[1])
  }

  private static func launchError(_ request: ProcessRequest, _ code: Int32) -> ProcessRunnerError {
    .launchFailed(executable: request.executable.path, reason: String(cString: strerror(code)))
  }
}
