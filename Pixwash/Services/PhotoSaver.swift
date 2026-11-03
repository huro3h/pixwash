import Foundation
import Photos

nonisolated enum PhotoSaver {
    enum Failure: LocalizedError {
        case denied

        var errorDescription: String? {
            "写真への追加が許可されていません。設定アプリの「Pixwash > 写真」で許可してください。"
        }
    }

    /// 書き出したファイルのバイト列をそのまま写真ライブラリに追加する。
    /// UIImage を経由すると iOS が再エンコードしてしまうので、データで渡す。
    /// ファイル名を渡さないと写真ライブラリが連番の「IMG_6780」のような名前を付け、時期を推測できてしまう
    static func save(_ data: Data, fileName: String) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Failure.denied }
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = fileName
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: options)
        }
    }
}
