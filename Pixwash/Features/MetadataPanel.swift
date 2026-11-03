import MapKit
import SwiftUI

struct MetadataPanel: View {
    /// 写真を選ぶ前は nil
    let metadata: PhotoMetadata?
    @Binding var stripMetadata: Bool

    var body: some View {
        Form {
            Section {
                Toggle("保存・共有時にメタデータを削除", isOn: $stripMetadata)
            } footer: {
                if stripMetadata {
                    Text("位置情報・撮影日時・機種などは書き出す画像に含まれません。")
                } else if metadata?.hasLocation == true {
                    Text("位置情報が含まれたまま書き出されます。")
                        .foregroundStyle(.orange)
                }
            }

            if let metadata {
                details(metadata)
            } else {
                Section("この写真に含まれる情報") {
                    Text("写真を選ぶと、位置情報・撮影日時・機種などをここに表示します。")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func details(_ metadata: PhotoMetadata) -> some View {
        Section("この写真に含まれる情報") {
            row("撮影日時", metadata.takenAt)
            row("機種", metadata.camera)
            row("レンズ", metadata.lens)
            row("ソフトウェア", metadata.software)
            if let latitude = metadata.latitude, let longitude = metadata.longitude {
                let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                LabeledContent("位置情報") {
                    Text(String(format: "%.5f, %.5f", latitude, longitude))
                        .foregroundStyle(.orange)
                }
                Map(initialPosition: .region(MKCoordinateRegion(
                    center: coordinate, latitudinalMeters: 1000, longitudinalMeters: 1000
                ))) {
                    Marker("撮影地", coordinate: coordinate)
                }
                .frame(height: 160)
                .listRowInsets(EdgeInsets())
            } else {
                LabeledContent("位置情報", value: "なし")
            }
        }

        Section {
            DisclosureGroup("すべての項目") {
                ForEach(metadata.groups) { group in
                    Text(group.name)
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    ForEach(group.items) { item in
                        LabeledContent(item.label, value: item.value)
                            .font(.caption)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        LabeledContent(label, value: value ?? "なし")
    }
}
