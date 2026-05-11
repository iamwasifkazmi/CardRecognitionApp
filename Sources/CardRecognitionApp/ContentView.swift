import Observation
import SwiftUI

struct ContentView: View {
    @State private var model = ScannerViewModel()

    var body: some View {
        NavigationStack {
            SlotScannerDashboard(model: model)
                .navigationTitle("Slot Recognition")
#if os(iOS) && !targetEnvironment(simulator)
                .task {
                    await model.bootstrapIOSCamera()
                }
                .onDisappear {
                    model.teardownIOSCamera()
                }
#elseif os(iOS)
                .task {
                    await model.bootstrapIOSCamera()
                }
#endif
        }
    }
}

/// Shared rectangular “monitor style” framing for camera / import previews.
private enum ScanPreviewStyle {
    static let aspectRatio: CGFloat = 16 / 9
}

private struct SlotScannerDashboard: View {
    @Bindable var model: ScannerViewModel
#if os(iOS)
    @State private var showPhotoLibraryPicker = false
#endif

    var body: some View {
        ScrollView {
            VStack(alignment: .center, spacing: 14) {
                Group {
#if os(iOS) && !targetEnvironment(simulator)
                    IOSCameraPreview(session: model.captureSessionForPreview)
                        .scanPreviewChrome()
#elseif os(iOS) && targetEnvironment(simulator)
                    /// Never attach `AVCaptureVideoPreviewLayer` on Simulator — it still pings FigCapture (-12782) even with no inputs.
                    Rectangle()
                        .fill(Color.black)
                        .aspectRatio(ScanPreviewStyle.aspectRatio, contentMode: .fit)
                        .scanPreviewChromeStrokeOnly()
#else
                    Rectangle()
                        .fill(Color.secondary.opacity(0.12))
                        .aspectRatio(ScanPreviewStyle.aspectRatio, contentMode: .fit)
                        .overlay {
                            VStack(spacing: 10) {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 46))
                                    .symbolRenderingMode(.hierarchical)
                                Text("Import a screenshot using Import (Photos or Files).")
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 26)
                            }
                        }
                        .scanPreviewChromeStrokeOnly()
#endif
                }
                .padding(.horizontal)
                .containerRelativeFrame(.horizontal) { len, _ in len }
                .frame(maxWidth: .infinity)

                if let banner = model.statusBanner {
                    Text(banner)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal)
                }

                if model.isAnalyzing {
                    ProgressView("Reading five-slot row…")
                        .frame(maxWidth: .infinity)
                }

                if let snapshot = model.latestScan {
                    DetectedCardsTable(snapshot: snapshot)
                }

                DisclosureGroup("Privacy & scanning tips") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Privacy")
                            .font(.subheadline.weight(.semibold))
                        Text(
                            """
                            • Camera: Accessed only when you tap Capture & read. Images used for recognition are processed on your device; this app does not upload them to remote servers.\n• Photos & Files: You pick which images to open. They are read on your device for analysis only.
                            """
                        )
                        Text("Scanning accuracy")
                            .font(.subheadline.weight(.semibold))
                            .padding(.top, 4)
                        Text(
                            """
                            • Use a steady, well-lit view of the card row; reduce glare on shiny UI.\n• For best OCR, prefer a sharp screenshot over a motion-blurred photo.\n• You can revoke camera access anytime in Settings ▸ Privacy ▸ Camera.
                            """
                        )
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
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

#if os(iOS)
                Button {
                    showPhotoLibraryPicker = true
                } label: {
                    Label("Photo Library", systemImage: "photo.on.rectangle.angled")
                }
                .disabled(model.isAnalyzing)
                Button {
                    model.isImporterPresented = true
                } label: {
                    Label("Browse Files", systemImage: "folder")
                }
                .disabled(model.isAnalyzing)
#else
                Button {
                    model.isImporterPresented = true
                } label: {
                    Label("Import screenshot", systemImage: "folder")
                }
                .disabled(model.isAnalyzing)
#endif
            }
        }
#if os(iOS)
        .sheet(isPresented: $showPhotoLibraryPicker) {
            PhotoLibraryPHPicker(isPresented: $showPhotoLibraryPicker) { data in
                guard let data else {
                    model.statusBanner = """
Could not load this photo from your library. Try another image saved on this device, or use Browse Files.

If the photo is only in cloud storage or uses an unusual format, save a JPEG or PNG copy first, then import that file.
"""
                    return
                }
                Task {
                    await model.analyzeImportedImageData(data)
                    if model.latestScan != nil {
                        model.statusBanner = "Analyzed five cards from Photos."
                    }
                }
            }
        }
#endif
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

private enum ScanTableColumns {
    static let slot: CGFloat = 34
    static let rank: CGFloat = 52
    static let suit: CGFloat = 40
    static let confidence: CGFloat = 48
}

/// Five-slot summary table stretching to the usable width.
private struct DetectedCardsTable: View {
    let snapshot: CardVisionPipeline.ScanResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Detected row")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            let rowCards = Array(snapshot.cards.prefix(5))
            VStack(alignment: .leading, spacing: 0) {
                tableHeaderRow
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)

                Divider()

                ForEach(Array(rowCards.enumerated()), id: \.element.id) { index, card in
                    tableBodyRow(slot: index + 1, card: card)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    if index < rowCards.count - 1 {
                        Divider()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06))
            .clipShape(Rectangle())
            .overlay(Rectangle().strokeBorder(Color.secondary.opacity(0.28), lineWidth: 1))
        }
        .padding(.horizontal)
    }
}

private extension DetectedCardsTable {
    var tableHeaderRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("#")
                .frame(width: ScanTableColumns.slot, alignment: .leading)
            Text("Rank")
                .frame(width: ScanTableColumns.rank, alignment: .leading)
            Text("Suit")
                .frame(width: ScanTableColumns.suit, alignment: .center)
            Spacer(minLength: 0)
            Text("Conf.")
                .frame(width: ScanTableColumns.confidence, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .minimumScaleFactor(0.85)
    }

    func tableBodyRow(slot: Int, card: RecognizedPlayingCard) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text("\(slot)")
                .font(.callout.monospacedDigit())
                .frame(width: ScanTableColumns.slot, alignment: .leading)
                .foregroundStyle(.secondary)

            Text(card.rankTableLabel)
                .font(.body.monospaced().weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: ScanTableColumns.rank, alignment: .leading)

            Text(card.suitTableLabel)
                .font(.title3)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: ScanTableColumns.suit, alignment: .center)

            Spacer(minLength: 0)

            Text(card.percentConfidenceText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .frame(width: ScanTableColumns.confidence, alignment: .trailing)
        }
    }
}

private extension View {
    @ViewBuilder
    func scanPreviewChrome() -> some View {
        self
            .aspectRatio(ScanPreviewStyle.aspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(Rectangle())
            .overlay(Rectangle().strokeBorder(.secondary.opacity(0.4), lineWidth: 1))
    }

    @ViewBuilder
    func scanPreviewChromeStrokeOnly() -> some View {
        self
            .frame(maxWidth: .infinity)
            .clipShape(Rectangle())
            .overlay(Rectangle().strokeBorder(.secondary.opacity(0.4), lineWidth: 1))
    }
}

extension RecognizedPlayingCard {
    fileprivate var percentConfidenceText: String {
        guard confidence.isFinite else { return "—" }
        let scaled = Double(confidence) > 1.0 ? Double(confidence) : Double(confidence) * 100
        return String(format: "%.0f%%", scaled)
    }

    fileprivate var detailsLabel: String {
        let confidenceLine = "Confidence \(percentConfidenceText)"
        if diagnosis.isEmpty {
            return confidenceLine
        }
        return "\(diagnosis)\n\(confidenceLine)"
    }
}

#Preview("Slot scanner") {
    ContentView()
}
