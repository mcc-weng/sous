import XCTest
@testable import Sous

final class UIImageCroppedToSquareTests: XCTestCase {
    private func makeImage(width: Int, height: Int, scale: CGFloat, orientation: UIImage.Orientation) -> UIImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(UIColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = context.makeImage()!
        return UIImage(cgImage: cgImage, scale: scale, orientation: orientation)
    }

    func testCroppedToSquareProducesCorrectPointSizeForRightOrientedImage() {
        // A portrait camera capture: raw cgImage is landscape (4032x3024 raw pixels,
        // scale 1 — matching real UIImagePickerController .originalImage output),
        // reported as .right orientation, which UIKit renders as portrait — exactly
        // the shape that broke both prior attempts at this function (orientation
        // mismatch in round 1, renderer-scale mismatch in round 2's fix).
        let image = makeImage(width: 4032, height: 3024, scale: 1, orientation: .right)
        XCTAssertEqual(image.size, CGSize(width: 3024, height: 4032)) // sanity: logical size is portrait

        let cropped = image.croppedToSquare()

        // Deliberately NOT just asserting width == height — a squareness-only check
        // passed round 2's scale bug (it produced a square, just the wrong size:
        // side/scale points instead of side points). Assert the actual point value.
        XCTAssertEqual(cropped.size.width, 3024, accuracy: 0.5)
        XCTAssertEqual(cropped.size.height, 3024, accuracy: 0.5)
        XCTAssertEqual(cropped.imageOrientation, .up)
    }

    func testCroppedToSquareHandlesAlreadySquareUpOrientedImage() {
        let image = makeImage(width: 500, height: 500, scale: 2, orientation: .up)
        let cropped = image.croppedToSquare()
        XCTAssertEqual(cropped.size.width, 250, accuracy: 0.5)
        XCTAssertEqual(cropped.size.height, 250, accuracy: 0.5)
        XCTAssertEqual(cropped.imageOrientation, .up)
    }
}
