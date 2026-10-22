import Foundation
import InstanceBuilder
import Testing
@testable import UI

@MainActor
@Suite struct MoveToApplicationsTests {
  let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

  func offers(_ location: AppLocation, _ path: String) -> Bool {
    MoveToApplications.shouldOffer(location, bundle: URL(fileURLWithPath: path, isDirectory: true), home: home)
  }

  @Test func anAppInApplicationsIsLeftAlone() {
    #expect(!offers(.applications, "/Applications/ClaudeMultiAcc.app"))
  }

  @Test func aTranslocatedDownloadIsOffered() {
    #expect(offers(.translocated, "/private/var/folders/x/AppTranslocation/ABC/d/ClaudeMultiAcc.app"))
  }

  @Test(arguments: [
    "/Users/tester/Downloads/ClaudeMultiAcc.app", "/Users/tester/Downloads/x/ClaudeMultiAcc.app",
    "/Users/tester/Desktop/ClaudeMultiAcc.app", "/Volumes/ClaudeMultiAcc/ClaudeMultiAcc.app",
  ])
  func downloadsDesktopAndDiskImagesAreOffered(path: String) {
    #expect(offers(.elsewhere, path))
  }

  /// «Не сейчас» is remembered for that copy; a translocated copy gets a new random path, so it is asked again.
  @Test func aDeclinedCopyIsNotAskedAgain() {
    let disk = URL(fileURLWithPath: "/Volumes/ClaudeMultiAcc/ClaudeMultiAcc.app", isDirectory: true)
    #expect(!MoveToApplications.shouldOffer(.elsewhere, bundle: disk, home: home, declinedPath: disk.path))
    let other = "/Volumes/Apps/ClaudeMultiAcc.app"
    #expect(MoveToApplications.shouldOffer(.elsewhere, bundle: disk, home: home, declinedPath: other))
  }

  /// A developer's build (`dist/`) runs from wherever it was built: no question on every launch.
  @Test(arguments: [
    "/Users/tester/Documents/GitHub/ClaudeMultiAcc/dist/ClaudeMultiAcc.app", "/Users/tester/DownloadsOld/ClaudeMultiAcc.app",
    "/opt/ClaudeMultiAcc.app",
  ])
  func otherPlacesAreLeftAlone(path: String) {
    #expect(!offers(.elsewhere, path))
  }
}
