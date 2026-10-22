import CoreGraphics
import Foundation
import Testing
@testable import IconRenderer

@Suite struct AppIconSourceTests {
  @Test func largestRepresentationFloor() {
    #expect(AppIconSource.isLargeEnough(representationPixels: [32, 64, 1024], minimumPixels: 512))
    #expect(!AppIconSource.isLargeEnough(representationPixels: [32, 256], minimumPixels: 512))
    #expect(!AppIconSource.isLargeEnough(representationPixels: [], minimumPixels: 512))
  }

  @Test func transparentImagesAreRejected() throws {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(
      data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let empty = try #require(context.makeImage())
    #expect(!AppIconSource.hasVisiblePixels(empty))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 2, y: 2, width: 1, height: 1))
    #expect(AppIconSource.hasVisiblePixels(try #require(context.makeImage())))
  }
}
