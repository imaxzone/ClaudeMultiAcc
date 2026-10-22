import Foundation
import Testing
@testable import cmacc

/// The ClaudeMultiAcc.app that `cmacc` belongs to: the bundle it runs from, else the installed copy.
@Suite struct OwnAppTests {
  let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

  @Test func cmaccInsideAnAppBundleUsesThatBundle() {
    let executable = URL(fileURLWithPath: "/Applications/ClaudeMultiAcc.app/Contents/Helpers/cmacc")
    #expect(OwnApp.url(executable: executable, home: home) { _ in false }.path == "/Applications/ClaudeMultiAcc.app")
    let elsewhere = URL(fileURLWithPath: "/Users/tester/dist/ClaudeMultiAcc.app/Contents/Helpers/cmacc")
    #expect(OwnApp.url(executable: elsewhere, home: home) { _ in true }.path == "/Users/tester/dist/ClaudeMultiAcc.app")
  }

  @Test func aLooseBinaryPrefersApplicationsThenTheUserFolder() {
    let loose = URL(fileURLWithPath: "/Users/tester/src/.build/debug/cmacc")
    #expect(OwnApp.url(executable: loose, home: home) { $0 == "/Applications/ClaudeMultiAcc.app" }.path
      == "/Applications/ClaudeMultiAcc.app")
    #expect(OwnApp.url(executable: loose, home: home) { _ in false }.path
      == "/Users/tester/Applications/ClaudeMultiAcc.app")
  }
}
