import Foundation
import Testing
@testable import InstanceBuilder

@Suite struct AncestryCheckTests {
  @Test func liveChainOfTheTestProcessIsNonEmptyAndAbsolute() {
    let chain = AncestryCheck().ancestorExecutablePaths()
    #expect(!chain.isEmpty)
    #expect(chain.allSatisfy { $0.hasPrefix("/") })
    #expect(chain.count < 64)
  }

  @Test func injectedChainIsReturnedAsIs() {
    let check = AncestryCheck(provider: { ["/bin/zsh", "/Applications/Claude.app/Contents/MacOS/Claude"] })
    #expect(check.ancestorExecutablePaths() == ["/bin/zsh", "/Applications/Claude.app/Contents/MacOS/Claude"])
  }

  @Test func hostAppIsTheOutermostAppBundle() {
    let chain = [
      "/usr/local/bin/cmacc", "/bin/zsh",
      "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper",
      "/Applications/Claude.app/Contents/MacOS/Claude", "/sbin/launchd",
    ]
    #expect(AncestryCheck.hostApp(in: chain) == "/Applications/Claude.app")
    #expect(AncestryCheck.hostApp(in: ["/bin/zsh", "/sbin/launchd"]) == nil)
  }

  @Test func insideDetectsOnlyPathsUnderTheBundle() {
    let app = URL(fileURLWithPath: "/Applications/Claude 2nd.app", isDirectory: true)
    #expect(AncestryCheck.anyInside(app, ["/bin/zsh", "/Applications/Claude 2nd.app/Contents/MacOS/Claude.real"]))
    #expect(!AncestryCheck.anyInside(app, ["/Applications/Claude 2nd.app.bak/x", "/Applications/Claude.app/Contents/MacOS/Claude"]))
  }
}
