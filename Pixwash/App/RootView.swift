import PhotosUI
import SwiftUI

struct RootView: View {
    @State private var model = EditorModel()
    @State private var selection: PhotosPickerItem?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            EditorView(model: model, selection: $selection)
                .overlay {
                    if isLoading {
                        ProgressView()
                            .controlSize(.large)
                            .padding(24)
                            .background(.regularMaterial, in: .rect(cornerRadius: 16))
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // 写真を選ぶ前は、写真の場所の「写真を選ぶ」から選ぶ
                    if model.photo != nil {
                        ToolbarItem(placement: .topBarLeading) {
                            // .current: HEIC などを JPEG に変換させず、元のファイルのまま受け取る(メタデータも残っている)
                            PhotosPicker(selection: $selection, matching: .images, preferredItemEncoding: .current) {
                                Image(systemName: "photo.on.rectangle")
                            }
                        }
                    }
                }
        }
        .onChange(of: selection) { _, item in
            guard let item else { return }
            Task { await load(item) }
        }
        .alert("エラー", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
        .task {
            // 前回共有用に書き出したファイルを片付ける
            ImageExporter.clearExportDirectory()
            #if DEBUG
            // シミュレータでは写真ピッカーを自動操作できないので、確認用に起動時に画像を開けるようにしている。
            // xcrun simctl launch --env 経由では渡らないので SIMCTL_CHILD_PIXWASH_OPEN=<パス> で渡す
            if let path = ProcessInfo.processInfo.environment["PIXWASH_OPEN"],
               let data = FileManager.default.contents(atPath: path),
               let photo = try? await ImageDecoder.decode(data) {
                model.open(photo)
            }
            #endif
        }
    }

    private func load(_ item: PhotosPickerItem) async {
        isLoading = true
        defer {
            isLoading = false
            selection = nil
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw ImageDecoder.Failure.unreadable
            }
            model.open(try await ImageDecoder.decode(data))
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
