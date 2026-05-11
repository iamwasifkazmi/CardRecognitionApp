import Observation
import SwiftUI

struct ContentView: View {
    @State private var model = ScannerViewModel()

    var body: some View {
        NavigationStack {
            SlotScannerDashboard(model: model)
                .navigationTitle("Slot Recognition")
#if os(iOS)
                .task {
                    await model.bootstrapIOSCamera()
                }
                .onDisappear {
                    model.teardownIOSCamera()
                }
#endif
        }
    }
}

private struct SlotScannerDashboard: View {
    @Bindable var model: ScannerViewModel

    var body: some View {
        VStack(spacing: 14) {
            Group {
#if os(iOS)
                IOSCameraPreview(session: model.captureSessionForPreview)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(.secondary.opacity(0.35))
                    )
                    .aspectRatio(3 / 5, contentMode: .fit)
#else
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
                    .aspectRatio(3 / 5, contentMode: .fit)
                    .overlay {
                        VStack(spacing: 10) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 46))
                                .symbolRenderingMode(.hierarchical)
                            Text("Import a PNG/JPEG screenshot of five slot cards using the folder button.")
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 26)
                        }
                    }
#endif
            }
            .padding(.horizontal)

            if let banner = model.statusBanner {
                Text(banner)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            if model.isAnalyzing {
                ProgressView("Reading five-slot row…")
            }

            if let snapshot = model.latestScan {
                FiveCardRow(snapshot: snapshot)
            }

            DisclosureGroup("Camera privacy & accuracy tips") {
                Text(
                    """
                    Run on Simulator from XcodeIosHost/CardRecognitionApp.xcodeproj (proper .app bundle + bundle ID). Opening only Package.swift can produce a bare SPM executable without CFBundleIdentifier, which crashes UIKit on launch.

                    Camera usage text lives in XcodeIosHost/App/Info.plist (duplicate of Supporting/AppInfo.plist). Vision rectangle detection plus perspective warp normalizes screenshots before OCR reads rank markers. Extremely glossy chrome, motion blur, or stylized typography may still confuse OCR—train a companion Core ML classifier and assign it via CardVisionPipeline.coreMLClassifierRequest after preprocessing training data with OpenCV or native Core Image kernels.
                    """
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
#if os(iOS)
                Button {
                    Task { await model.analyzeLiveScene() }
                } label: {
                    Label("Capture & read", systemImage: "camera.viewfinder")
                }
                .disabled(model.isAnalyzing)
#endif

                Button {
                    model.isImporterPresented = true
                } label: {
                    Label("Import screenshot", systemImage: "folder")
                }
                .disabled(model.isAnalyzing)
            }
        }
        .fileImporter(
            isPresented: $model.isImporterPresented,
            allowedContentTypes: [.image, .jpeg, .png, .gif, .heic, .tiff],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await model.analyzeImportedFile(url: url) }
            case .failure(let failure):
                model.statusBanner = failure.localizedDescription
            }
        }
#if os(macOS)
        .padding()
#endif
    }
}

private struct FiveCardRow: View {
    let snapshot: CardVisionPipeline.ScanResult

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Detected row")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(snapshot.cards.prefix(5)) { card in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(card.shortLabel)
                            .font(.headline.monospaced())
                        Text(card.detailsLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.thinMaterial))
                }
            }
        }
        .padding(.horizontal)
    }
}

extension RecognizedPlayingCard {
    fileprivate var detailsLabel: String {
        let confidenceLine = "Confidence \(formatConfidence(confidence))"
        if diagnosis.isEmpty {
            return confidenceLine
        }
        return "\(diagnosis)\n\(confidenceLine)"
    }

    fileprivate func formatConfidence(_ confidence: Float) -> String {
        guard confidence.isFinite else { return "—" }
        let scaled = Double(confidence) > 1.0 ? Double(confidence) : Double(confidence) * 100
        return String(format: "%.0f%%", scaled)
    }
}

#Preview("Slot scanner") {
    ContentView()
}
