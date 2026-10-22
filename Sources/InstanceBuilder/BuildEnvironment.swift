import Foundation
import Support

/// The machine-facing inputs of a build, injectable so pipeline tests never depend on the real machine (G6).
public struct BuildEnvironment: Sendable {
  public static let defaultMinimumFreeBytes: Int64 = 2_000_000_000

  public let running: any RunningChecking
  public let vendorUpdate: @Sendable (URL) -> any VendorUpdateChecking
  public let availableBytes: @Sendable (URL) -> Int64?
  public let minimumFreeBytes: Int64
  public let sourcePolicy: SourcePolicy

  public init(
    running: any RunningChecking, vendorUpdate: @escaping @Sendable (URL) -> any VendorUpdateChecking,
    availableBytes: @escaping @Sendable (URL) -> Int64?, minimumFreeBytes: Int64 = defaultMinimumFreeBytes,
    sourcePolicy: SourcePolicy
  ) {
    self.running = running
    self.vendorUpdate = vendorUpdate
    self.availableBytes = availableBytes
    self.minimumFreeBytes = minimumFreeBytes
    self.sourcePolicy = sourcePolicy
  }

  /// Real checks: NSRunningApplication/lsappinfo/lock, launchctl + process scan, volume capacity. A source inside
  /// `downloads` (`Paths.claudeSourcesDir`) skips the ShipIt check: ShipIt only replaces the app it was started from,
  /// and ClaudeMultiAcc's own downloads are never started.
  public static func live(runner: ProcessRunning, sourcePolicy: SourcePolicy = .vendor, downloads: URL? = nil)
    -> BuildEnvironment
  {
    BuildEnvironment(
      running: RunningCheck(runner: runner),
      vendorUpdate: { source in
        if let downloads, LaunchServicesCleanup.isInside(source, downloads) { return NoVendorUpdate() }
        return VendorUpdateCheck(runner: runner, sourceApp: source)
      },
      availableBytes: volumeAvailableBytes, sourcePolicy: sourcePolicy)
  }

  @Sendable static func volumeAvailableBytes(_ url: URL) -> Int64? {
    let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage
  }
}

/// A source no ShipIt ever replaces (a Claude ClaudeMultiAcc downloaded itself).
struct NoVendorUpdate: VendorUpdateChecking {
  func state() async -> VendorUpdateState { .idle }
}
