import SwiftUI

struct MosaicPanel: View {
    @Bindable var model: EditorModel
    @Binding var brushSize: Double

    var body: some View {
        Form {
            Section {
                Picker("隠し方", selection: $model.concealKind) {
                    ForEach(ConcealKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("太さ") {
                    Slider(value: $brushSize, in: 8...80)
                }
                let strengthLabel = model.concealKind == .mosaic ? "粗さ" : "強さ"
                LabeledContent(strengthLabel) {
                    // 強さごとに加工済みの画像を作るので、段階を区切って種類を増やしすぎないようにする。
                    // 段階があると分かるよう、選べる位置に目盛りを出す
                    Slider(value: $model.strength, in: 0...1, step: 0.1) {
                        Text(strengthLabel)
                    } tick: { value in
                        SliderTick(value)
                    }
                }
                HStack {
                    Button("1つ戻す", systemImage: "arrow.uturn.backward") {
                        _ = model.strokes.popLast()
                    }
                    Spacer()
                    Button("すべて消す", systemImage: "trash", role: .destructive) {
                        model.strokes.removeAll()
                    }
                }
                .buttonStyle(.borderless)
                .disabled(model.strokes.isEmpty)
            } footer: {
                Text("写真を指でなぞり、指を離すとその線の部分がモザイク(またはぼかし)になります。ここでの設定は、これからなぞる線に使います。")
            }
        }
    }
}
