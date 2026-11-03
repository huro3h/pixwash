import SwiftUI

struct ResizePanel: View {
    @Binding var settings: ExportSettings
    /// 元の写真のサイズ(写真を選ぶ前は nil)
    let original: PixelSize?
    /// 元の写真が HDR か(写真を選ぶ前は nil)
    let hasHDR: Bool?

    private static let longEdgePresets = [720, 1080, 1280, 1920, 2560, 3840]

    var body: some View {
        Form {
            Section {
                Picker("サイズ", selection: $settings.resizeMode) {
                    ForEach(ResizeMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                switch settings.resizeMode {
                case .original:
                    EmptyView()
                case .percent:
                    LabeledContent("\(Int(settings.percent))%") {
                        Slider(value: $settings.percent, in: 5...100, step: 5)
                    }
                case .longEdge:
                    LabeledContent("長辺") {
                        TextField("px", value: $settings.longEdge, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 100)
                        Text("px")
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(Self.longEdgePresets, id: \.self) { value in
                                Button("\(value)") { settings.longEdge = value }
                                    .buttonStyle(.bordered)
                                    .tint(settings.longEdge == value ? .accentColor : .secondary)
                                    .disabled(original.map { value >= $0.longEdge } ?? false)
                            }
                        }
                    }
                }
            } footer: {
                if settings.resizeMode == .longEdge, let original, settings.longEdge >= original.longEdge {
                    Text("元の長辺(\(original.longEdge)px)より大きくはしません。")
                }
            }

            Section {
                Picker("形式", selection: $settings.format) {
                    ForEach(OutputFormat.allCases) { Text($0.label).tag($0) }
                }
                if settings.format == .jpeg {
                    LabeledContent("画質 \(Int(settings.jpegQuality * 100))") {
                        Slider(value: $settings.jpegQuality, in: 0.3...1, step: 0.05)
                    }
                }
                Toggle("HDR を保つ", isOn: $settings.keepsHDR)
            } footer: {
                if settings.keepsHDR {
                    if !settings.format.supportsGainMap {
                        Text("PNG では HDR を保てません。HDR の明るさを保つには JPEG にしてください。")
                    } else if hasHDR == false {
                        Text("この写真には HDR の情報がありません。")
                    } else {
                        Text("HDR の写真は、明るさの情報を作り直して付けます。位置情報などのメタデータとは別で、メタデータを削除しても明るさは保たれます。")
                    }
                }
            }
        }
    }
}
