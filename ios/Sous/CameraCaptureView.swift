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
    /// regardless of what aspect ratio the camera/library hands back. Normalizes
    /// orientation first: `UIImage.size` is orientation-corrected, but the raw
    /// `cgImage` backing store is not — cropping the raw buffer directly against
    /// orientation-aware `size` produces a wrong-axis crop for any non-`.up`
    /// orientation, which is most portrait camera captures (they come back `.right`).
    func croppedToSquare() -> UIImage {
        let normalized = normalizedToUpOrientation()
        let side = min(normalized.size.width, normalized.size.height)
        let origin = CGPoint(x: (normalized.size.width - side) / 2, y: (normalized.size.height - side) / 2)
        guard let cgImage = normalized.cgImage,
              let cropped = cgImage.cropping(to: CGRect(origin: origin, size: CGSize(width: side, height: side)))
        else { return normalized }
        return UIImage(cgImage: cropped, scale: normalized.scale, orientation: .up)
    }

    private func normalizedToUpOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: size)) }
    }
}
