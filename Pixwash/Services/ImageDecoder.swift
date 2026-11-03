import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 読み込んだ写真。画像は向き(Exif の Orientation)を反映済み。
nonisolated struct LoadedPhoto: Identifiable, Sendable {
    let id = UUID()
    /// 元のファイルのバイト列(メタデータを残して書き出すときに読み直す)
    let data: Data
    /// 元の解像度の画像。書き出しに使う
    let full: CGImage
    /// 画面表示用に縮めた画像。モザイクの描画はこちらで行う
    let preview: CGImage
    let metadata: PhotoMetadata
    let type: UTType?
    /// HDR の明るさの補助画像(ゲインマップ)を持っているか
    let hasHDR: Bool

    var size: PixelSize { PixelSize(full) }
}

nonisolated enum ImageDecoder {
    enum Failure: LocalizedError {
        case unreadable

        var errorDescription: String? { "画像を読み込めませんでした。" }
    }

    /// 表示用画像の長辺。指でなぞる精度には十分で、モザイクの再計算も軽い
    static let previewLongEdge = 2048

    @concurrent
    static func decode(_ data: Data) async throws -> LoadedPhoto {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw Failure.unreadable
        }
        let longEdge = max(width, height)
        guard let full = orientedImage(source, maxPixelSize: longEdge),
              let preview = orientedImage(source, maxPixelSize: min(longEdge, previewLongEdge)) else {
            throw Failure.unreadable
        }
        return LoadedPhoto(
            data: data,
            full: full,
            preview: preview,
            metadata: PhotoMetadata(properties: properties),
            type: CGImageSourceGetType(source).flatMap { UTType($0 as String) },
            hasHDR: [kCGImageAuxiliaryDataTypeISOGainMap, kCGImageAuxiliaryDataTypeHDRGainMap].contains {
                CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, $0) != nil
            }
        )
    }

    /// ゲインマップを当てた HDR の画像(拡張範囲の色空間、1.0 を超える明るさを持つ)を、向きを反映して読む。
    /// 書き出す大きさで読めば、元の大きさの HDR 画像(普通の画像の倍のメモリ)を作らずに済む
    static func hdrImage(_ data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              ImageExporter.isHDR(image) else { return nil }
        return image
    }

    /// サムネイル作成の API を使うと、Orientation を画素に焼き込んだ画像が得られる。
    /// 最大サイズを元の長辺にすれば縮小されない。
    private static func orientedImage(_ source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
