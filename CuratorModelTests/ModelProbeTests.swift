import XCTest
import FoundationModels
import CoreGraphics
@testable import Curator

@MainActor
final class ModelProbeTests: XCTestCase {
    /// A real model integration gate, separate from deterministic safety and UI tests.
    /// This verifies image transport only; it is not a photo recommendation quality evaluation.
    func testRealImageModelUnderstandsImageInput() async throws {
        guard ModelReadiness.current() == .ready else {
            throw XCTSkip("On-device vision is unavailable. Use a compatible macOS 27 Simulator host or an eligible iOS 27 device.")
        }
        let context = try XCTUnwrap(CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        let image = try XCTUnwrap(context.makeImage())
        do {
            let response = try await LanguageModelSession(model: SystemLanguageModel.default).respond {
                "What is the main colour in this image? Answer with one English colour word."
                Attachment(image).label("probe")
            }
            XCTAssertTrue(response.content.lowercased().contains("red"))
        } catch {
            // Raw framework errors can contain unserialisable userInfo in Xcode 27 RC.
            XCTFail("Real image inference failed: \(error.localizedDescription)")
        }
    }
}
