// ios/Sous/CameraCaptureView.swift
import SwiftUI
import UIKit

/// Wraps `UIImagePickerController` for 上菜's `拍照` button — the system camera sheet,
/// not a bespoke `AVCaptureSession` view (design spec: too much camera-lifecycle code
/// for a screen used once per cook). Falls back to the photo library when no camera is
/// available (the simulator has none), so the feature is testable without a device.
struct CameraCaptureView: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraCaptureView
        init(_ parent: CameraCaptureView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image.croppedToSquare())
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

extension UIImage {
    /// Center-crops to a 1:1 square — the design's photo target is always square
    /// regardless of what aspect ratio the camera/library hands back. Works entirely
    /// in UIKit's point-based coordinate space via `draw(at:)`, which is orientation-
    /// and scale-aware by construction. This deliberately avoids a raw `CGImage`-level
    /// crop: two prior attempts at that approach each introduced a silently-wrong,
    /// non-crashing crop — first because `cgImage`'s pixel buffer isn't
    /// orientation-corrected (a `.right`-oriented portrait photo has cgImage
    /// width/height swapped relative to `size`), then because
    /// `UIGraphicsImageRenderer`'s default format scale is the device's screen scale,
    /// not the source image's, so a subsequent points-based crop rect was
    /// misinterpreted as pixel coordinates on an oversized buffer. `draw(at:)` and a
    /// pinned `format.scale` keep every coordinate in the same space throughout, so
    /// there's no unit mismatch left to reintroduce.
    func croppedToSquare() -> UIImage {
        let side = min(size.width, size.height)
        let origin = CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        return renderer.image { _ in
            self.draw(at: CGPoint(x: -origin.x, y: -origin.y))
        }
    }
}
