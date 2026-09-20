import SwiftUI
import PhotosUI
import VisionKit
import Vision

// System pickers are user-initiated. Photos may retrieve an iCloud original;
// the app itself has no network client and never uploads the selected content.
struct LocalImagePicker: UIViewControllerRepresentable {
    enum Source: Equatable { case camera, library, document }
    let source: Source
    let completion: ([Data]?, String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    func makeUIViewController(context: Context) -> UIViewController {
        switch source {
        case .camera:
            let picker = UIImagePickerController()
            picker.sourceType = .camera
            picker.delegate = context.coordinator
            return picker
        case .library:
            var config = PHPickerConfiguration()
            config.filter = .images
            config.selectionLimit = 1
            let picker = PHPickerViewController(configuration: config)
            picker.delegate = context.coordinator
            return picker
        case .document:
            let scanner = VNDocumentCameraViewController()
            scanner.delegate = context.coordinator
            return scanner
        }
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}

    @MainActor final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate,
        PHPickerViewControllerDelegate, VNDocumentCameraViewControllerDelegate {
        let completion: ([Data]?, String?) -> Void
        init(completion: @escaping ([Data]?, String?) -> Void) { self.completion = completion }

        // Render orientation into pixels and omit source EXIF/GPS metadata.
        private func jpeg(_ image: UIImage) -> Data? {
            let maxSide: CGFloat = 3000
            let scale = min(1, maxSide / max(image.size.width, image.size.height))
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }.jpegData(compressionQuality: 0.9)
        }

        func imagePickerController(_ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage, let data = jpeg(image) else {
                completion(nil, "The photo could not be decoded.")
                return
            }
            completion([data], nil)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { completion(nil, nil) }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let result = results.first else { completion(nil, nil); return }
            result.itemProvider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, error in
                let failure = error?.localizedDescription
                Task { @MainActor in
                    guard let data, let image = UIImage(data: data), let jpeg = self.jpeg(image) else {
                        self.completion(nil, failure ?? "The selected photo could not be loaded. Try an image stored on this device.")
                        return
                    }
                    self.completion([jpeg], nil)
                }
            }
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan) {
            var pages: [Data] = []
            for index in 0..<scan.pageCount {
                guard let data = jpeg(scan.imageOfPage(at: index)) else {
                    completion(nil, "A scanned page could not be decoded. Please scan again.")
                    return
                }
                pages.append(data)
            }
            completion(pages, nil)
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { completion(nil, nil) }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            completion(nil, error.localizedDescription)
        }
    }
}

enum LocalCaptureOCR {
    static func recognize(_ pages: [Data]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try pages.map { data in
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                try VNImageRequestHandler(data: data).perform([request])
                return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            }.joined(separator: "\n\n")
        }.value
    }
}
