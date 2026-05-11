#if os(iOS)

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Library import without SwiftUI **`PhotosPicker` / `PhotosPickerItem`**, which funnel through
/// **`NSItemProvider`** + **`public.jpeg`** and reproduce CloudPhotos / Simulator churn (`3303`, `1006`, etc.).
struct PhotoLibraryPHPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    /// Invoked on the main actor once bytes are resolved (or `nil` on failure).
    var onPick: @MainActor @Sendable (Data?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 1
        if #available(iOS 15.0, *) {
            configuration.preferredAssetRepresentationMode = .compatible
        }

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        var parent: PhotoLibraryPHPicker

        init(parent: PhotoLibraryPHPicker) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            Task {
                if results.isEmpty {
                    await MainActor.run { parent.isPresented = false }
                    return
                }

                let picked: Data?
                if let provider = results.first?.itemProvider {
                    picked = await Self.bytes(from: provider)
                } else {
                    picked = nil
                }
                await MainActor.run {
                    parent.isPresented = false
                    parent.onPick(picked)
                }
            }
        }

        nonisolated private static func bytes(from provider: NSItemProvider) async -> Data? {
            /// Specific → generic. Prefer file-backed copies over `public.jpeg` blobs when possible.
            let ordered: [String] = [
                UTType.heic.identifier,
                UTType.heif.identifier,
                UTType.jpeg.identifier,
                UTType.png.identifier,
                UTType.gif.identifier,
                UTType.tiff.identifier,
                UTType.bmp.identifier,
                UTType.webP.identifier,
                UTType.image.identifier,
                "public.data",
            ]
            let preferred = Set(ordered)

            for uti in ordered where provider.hasItemConformingToTypeIdentifier(uti) {
                if let file = await loadFileRepresentation(provider: provider, uti: uti) {
                    return file
                }
                if let blob = await loadDataRepresentation(provider: provider, uti: uti) {
                    return blob
                }
            }

            let extras = provider.registeredTypeIdentifiers.filter { preferred.contains($0) == false }
            for uti in extras {
                if let file = await loadFileRepresentation(provider: provider, uti: uti) {
                    return file
                }
                if let blob = await loadDataRepresentation(provider: provider, uti: uti) {
                    return blob
                }
            }

            return nil
        }

        nonisolated private static func loadFileRepresentation(provider: NSItemProvider, uti: String) async -> Data? {
            await withCheckedContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: uti) { url, _ in
                    guard let url else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer {
                        if scoped {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                    let data = try? Data(contentsOf: url)
                    continuation.resume(returning: (data?.isEmpty == false) ? data : nil)
                }
            }
        }

        nonisolated private static func loadDataRepresentation(provider: NSItemProvider, uti: String) async -> Data? {
            await withCheckedContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: uti) { data, _ in
                    continuation.resume(returning: (data?.isEmpty == false) ? data : nil)
                }
            }
        }
    }
}

#endif
