import Foundation

/// Compares dotted version strings by their numeric components (`1.2.10` > `1.2.9`; `1.2` == `1.2.0`).
/// Each component counts by its leading digits (`3-beta` → 3; no digits → 0).
public enum VersionCompare {
  public static func isNewer(_ a: String, than b: String) -> Bool {
    let left = components(a)
    let right = components(b)
    for index in 0..<max(left.count, right.count) {
      let l = index < left.count ? left[index] : 0
      let r = index < right.count ? right[index] : 0
      if l != r { return l > r }
    }
    return false
  }

  static func components(_ version: String) -> [Int] {
    guard !version.isEmpty else { return [] }
    return version.split(separator: ".", omittingEmptySubsequences: false).map { part in
      Int(part.prefix { $0.isASCII && $0.isNumber }) ?? 0
    }
  }
}
