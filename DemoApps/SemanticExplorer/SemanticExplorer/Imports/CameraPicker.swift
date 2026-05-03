import SwiftUI
import UIKit

/// A SwiftUI wrapper for UIImagePickerController to support taking photos with the camera.
struct CameraPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let onImageCaptured: (Data) -> Void
    let onFailure: (Error) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let uiImage = info[.originalImage] as? UIImage {
                // Per prompt: JPEG, 0.85 quality
                if let data = uiImage.jpegData(compressionQuality: 0.85) {
                    parent.onImageCaptured(data)
                } else {
                    parent.onFailure(NSError(domain: "CameraPicker", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to convert image to JPEG"]))
                }
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
