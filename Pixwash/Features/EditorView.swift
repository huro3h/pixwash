import PhotosUI
import SwiftUI

struct EditorView: View {
    @Bindable var model: EditorModel
    /// 写真を選ぶ前に、写真の場所に出す「写真を選ぶ」ボタンの選択結果
    @Binding var selection: PhotosPickerItem?

    enum Panel: String, CaseIterable, Identifiable {
        case mosaic = "モザイク"
        case size = "サイズ"
        case metadata = "メタデータ"

        var id: Self { self }
    }

    @State private var panel: Panel = .mosaic
    @State private var isSaving = false
    @State private var toast: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let photo = model.photo {
                    MosaicCanvas(
                        image: photo.preview,
                        concealed: model.concealedPreviews,
                        strokes: $model.strokes,
                        brushSize: model.brushSize,
                        effect: model.effect,
                        isDrawingEnabled: panel == .mosaic
                    )
                    // 写真を選び直したら拡大を戻す
                    .id(photo.id)
                } else {
                    photoPlaceholder
                }
            }
            .padding(8)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast)
                        .font(.callout)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: .capsule)
                        .padding(.bottom, 16)
                        .transition(.opacity)
                }
            }

            OutputSummary(model: model)
                .padding(.horizontal)
                .padding(.vertical, 6)
                // 写真がないときも高さを保ち、選んだときに下の操作部分が動かないようにする
                .frame(minHeight: 28)

            PanelSwitcher(selection: $panel, keepsMetadata: !model.settings.stripMetadata)
                .padding(.horizontal)

            Group {
                switch panel {
                case .mosaic:
                    MosaicPanel(model: model)
                case .size:
                    ResizePanel(settings: $model.settings, original: model.photo?.size, hasHDR: model.photo?.hasHDR)
                case .metadata:
                    MetadataPanel(metadata: model.photo?.metadata, stripMetadata: $model.settings.stripMetadata)
                }
            }
            .frame(height: 250)
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let result = model.currentResult {
                    ShareLink(item: result.fileURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                } else if model.photo != nil {
                    ProgressView()
                }
                Button {
                    Task { await save() }
                } label: {
                    Text("保存")
                }
                .disabled(isSaving || model.photo == nil)
            }
        }
        .task(id: EffectPreviewKey(photo: model.photo?.id, effect: model.effect)) {
            await model.prepareConcealedPreview()
        }
        .task(id: ExportTaskKey(photo: model.photo?.id, key: model.exportKey)) {
            // 設定を続けて動かしている間は書き出さない
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            _ = try? await model.export()
        }
        .alert("エラー", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
        .sensoryFeedback(.success, trigger: toast) { _, new in new != nil }
    }

    private var photoPlaceholder: some View {
        PhotosPicker(selection: $selection, matching: .images, preferredItemEncoding: .current) {
            VStack(spacing: 12) {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 44))
                Text("写真を選ぶ")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.fill.tertiary, in: .rect(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let result = try await model.export()
            try await PhotoSaver.save(result.data, fileName: result.fileURL.lastPathComponent)
            withAnimation { toast = "写真に保存しました" }
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { toast = nil }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// モザイク・サイズ・メタデータの切り替え。標準の segmented Picker は項目ごとに色を変えられないので自前で描く。
/// メタデータを残す設定のときは、気付けるようにメタデータのタブをオレンジにする(ユーザーの希望、2026-11-03)
private struct PanelSwitcher: View {
    @Binding var selection: EditorView.Panel
    let keepsMetadata: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(EditorView.Panel.allCases) { panel in
                let warns = panel == .metadata && keepsMetadata
                Button {
                    selection = panel
                } label: {
                    HStack(spacing: 4) {
                        if warns {
                            Image(systemName: "exclamationmark.circle.fill")
                                .imageScale(.small)
                        }
                        Text(panel.rawValue)
                    }
                    .font(.subheadline.weight(selection == panel ? .semibold : .regular))
                    .foregroundStyle(warns ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .background {
                        if selection == panel {
                            Capsule()
                                .fill(Color(uiColor: .systemBackground))
                                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                        }
                    }
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == panel ? .isSelected : [])
                .accessibilityHint(warns ? "メタデータを残す設定です" : "")
            }
        }
        .padding(3)
        .background(Color(uiColor: .tertiarySystemFill), in: .capsule)
        .animation(.snappy(duration: 0.2), value: selection)
    }
}

/// 写真を選び直したときにも、同じ設定のまま作り直すためのキー
private struct EffectPreviewKey: Equatable {
    let photo: UUID?
    let effect: ConcealEffect
}

private struct ExportTaskKey: Equatable {
    let photo: UUID?
    let key: ExportKey
}

/// 元画像と書き出し結果のサイズを並べる
private struct OutputSummary: View {
    let model: EditorModel

    var body: some View {
        if let photo = model.photo, let outputSize = model.outputSize {
            summary(photo: photo, outputSize: outputSize)
        }
    }

    private func summary(photo: LoadedPhoto, outputSize: PixelSize) -> some View {
        HStack(spacing: 6) {
            Text("\(photo.size.label)・\(byteCount(photo.data.count))")
                .foregroundStyle(.secondary)
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
            Text(outputSize.label)
            if let result = model.currentResult {
                Text("・\(byteCount(result.data.count))")
            } else {
                ProgressView()
                    .controlSize(.mini)
            }
            Spacer(minLength: 0)
            if model.settings.stripMetadata {
                Image(systemName: "location.slash")
                    .foregroundStyle(.green)
                    .accessibilityLabel("メタデータを削除")
            } else {
                Image(systemName: "location.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("メタデータを残す")
            }
        }
        .font(.caption.monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    private func byteCount(_ count: Int) -> String {
        Int64(count).formatted(.byteCount(style: .file))
    }
}
