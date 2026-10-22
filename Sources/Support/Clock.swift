import Foundation

/// Wall-clock source, injected so tests never depend on real time.
public protocol Clock: Sendable {
  var now: Date { get }
}

public struct SystemClock: Clock {
  public init() {}
  public var now: Date { Date() }
}
