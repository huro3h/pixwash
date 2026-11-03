import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import Security

nonisolated struct ExportResult: Sendable {
    let data: Data
    let size: PixelSize
    /// 共有用に一時フォルダへ書いたファイル
    let fileURL: URL
}

/// モザイクの合成・縮小・エンコードを行う。重いので呼び出し元のスレッドから外して動かす。
nonisolated enum ImageExporter {
    enum Failure: LocalizedError {
        case renderFailed
        case encodeFailed

        var errorDescription: String? {
            switch self {
            case .renderFailed: "画像の合成に失敗しました。"
            case .encodeFailed: "画像の書き出しに失敗しました。"
            }
        }
    }

    // CIContext はスレッドセーフで、作り直すと重いので1つを使い回す
    private static let ciContext = CIContext()

    static let exportDirectory = FileManager.default.temporaryDirectory
        .appending(path: "Export", directoryHint: .isDirectory)

    @concurrent
    static func concealed(_ image: CGImage, effect: ConcealEffect) async -> CGImage? {
        conceal(image, effect: effect)
    }

    @concurrent
    static func export(_ photo: LoadedPhoto, key: ExportKey) async throws -> ExportResult {
        var image = photo.full
        if !key.strokes.isEmpty {
            guard let composed = compose(base: image, strokes: key.strokes) else {
                throw Failure.renderFailed
            }
            image = composed
        }
        let target = key.settings.outputSize(for: PixelSize(image))
        if target != PixelSize(image) {
            guard let resized = resize(image, to: target) else { throw Failure.renderFailed }
            image = resized
        }
        let data = try encode(image, settings: key.settings, sourceData: photo.data)
        let url = try write(data, fileExtension: key.settings.format.fileExtension)
        return ExportResult(data: data, size: PixelSize(image), fileURL: url)
    }

    static func clearExportDirectory() {
        try? FileManager.default.removeItem(at: exportDirectory)
    }

    // MARK: - 画像処理

    /// 画像全体をモザイク/ぼかしにする。強さは画像の長辺に対する割合で決める。
    private static func conceal(_ image: CGImage, effect: ConcealEffect) -> CGImage? {
        let input = CIImage(cgImage: image)
        let amount = max(2, CGFloat(PixelSize(image).longEdge) * effect.fraction)
        // 端が透明と混ざって暗くならないよう、外側を端の色で埋めてから掛ける
        let output: CIImage?
        switch effect.kind {
        case .mosaic:
            let filter = CIFilter.pixellate()
            filter.inputImage = input.clampedToExtent()
            filter.scale = Float(amount)
            filter.center = .zero
            output = filter.outputImage
        case .blur:
            let filter = CIFilter.gaussianBlur()
            filter.inputImage = input.clampedToExtent()
            filter.radius = Float(amount)
            output = filter.outputImage
        }
        guard let output = output?.cropped(to: input.extent) else { return nil }
        return ciContext.createCGImage(output, from: input.extent, format: .RGBA8,
                                       colorSpace: drawableColorSpace(of: image))
    }

    /// なぞった部分だけ加工済みの画像を重ねる。隠し方が同じで続いている線ごとに、その隠し方の画像を切り抜いて重ねる。
    private static func compose(base: CGImage, strokes: [MosaicStroke]) -> CGImage? {
        let width = base.width
        let height = base.height
        guard let context = makeContext(width: width, height: height, like: base) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(base, in: rect)
        var concealed: [ConcealEffect: CGImage] = [:]
        for run in MosaicRun.runs(of: strokes) {
            guard let mosaic = concealed[run.effect] ?? conceal(base, effect: run.effect),
                  let mask = mask(for: run.strokes, width: width, height: height) else { return nil }
            concealed[run.effect] = mosaic
            context.saveGState()
            context.clip(to: rect, mask: mask)
            context.draw(mosaic, in: rect)
            context.restoreGState()
        }
        return context.makeImage()
    }

    /// 線をグレースケールの画像に白で描く(白の部分がモザイク/ぼかしになる)。
    /// 線の輪郭を1つのパスに足し合わせて clip すると、重なった部分の向き次第で穴が空くため、画像のマスクにしている。
    private static func mask(for strokes: [MosaicStroke], width: Int, height: Int) -> CGImage? {
        guard let maskContext = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        // 線の座標は左上が原点なので、上下を反転してから描く
        maskContext.translateBy(x: 0, y: CGFloat(height))
        maskContext.scaleBy(x: 1, y: -1)
        maskContext.setFillColor(gray: 1, alpha: 1)
        maskContext.setStrokeColor(gray: 1, alpha: 1)
        let unit = CGFloat(max(width, height))
        for stroke in strokes {
            stroke.draw(in: maskContext, unit: unit)
        }
        return maskContext.makeImage()
    }

    private static func resize(_ image: CGImage, to size: PixelSize) -> CGImage? {
        guard let context = makeContext(width: size.width, height: size.height, like: image) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return context.makeImage()
    }

    private static func makeContext(width: Int, height: Int, like image: CGImage) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: drawableColorSpace(of: image),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// 写真の色空間(Display P3 など)を保つ。RGB 以外(グレースケール・パレット)は sRGB に寄せる
    private static func drawableColorSpace(of image: CGImage) -> CGColorSpace {
        if let space = image.colorSpace, space.model == .rgb, space.supportsOutput {
            return space
        }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }

    // MARK: - エンコード

    private static func encode(_ image: CGImage, settings: ExportSettings, sourceData: Data) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, settings.format.utType.identifier as CFString, 1, nil
        ) else { throw Failure.encodeFailed }

        var properties: [CFString: Any] = [:]
        if !settings.stripMetadata {
            properties = carriedMetadata(from: sourceData, size: PixelSize(image))
        }
        // 画素はすでに正しい向きに焼き込んであるので、向きは常に「そのまま」
        properties[kCGImagePropertyOrientation] = 1
        if settings.format == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = settings.jpegQuality
        }
        // 渡した辞書にない項目は書き込まれない(元の Exif・GPS・XMP は引き継がれない)
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encodeFailed }
        return output as Data
    }

    /// メタデータを残す設定のとき、元画像から引き継ぐ項目。画素数と向きは書き出し後の値に直す。
    private static func carriedMetadata(from data: Data, size: PixelSize) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return [:] }
        var properties: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            properties[key] = original[key]
        }
        if var tiff = original[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = size.width
            exif[kCGImagePropertyExifPixelYDimension] = size.height
            properties[kCGImagePropertyExifDictionary] = exif
        }
        return properties
    }

    private static func write(_ data: Data, fileExtension: String) throws -> URL {
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        let url = exportDirectory.appending(path: "\(randomFileName()).\(fileExtension)")
        try data.write(to: url)
        return url
    }

    /// 日時や連番から撮影・保存の時期を推測されないよう、ファイル名はランダムにする。
    /// 紛らわしい文字(0/o、1/l など)は除いた英小文字と数字で、長さも 16〜30 文字からランダムに選ぶ。
    /// 乱数は暗号論的に安全な `SecRandomCopyBytes` で作る
    private static func randomFileName() -> String {
        let characters = Array("abcdefghijkmnpqrstuvwxyz23456789")
        let length = secureRandom(in: 16...30)
        return String((0..<length).map { _ in characters[secureRandom(in: 0...(characters.count - 1))] })
    }

    /// `SecRandomCopyBytes` で範囲内の整数を偏りなく選ぶ。
    /// 範囲の大きさで割り切れない上端の値は、剰余を取ると小さい値が出やすくなるので捨てて引き直す
    private static func secureRandom(in range: ClosedRange<Int>) -> Int {
        let count = UInt32(range.count)
        let limit = UInt32.max - UInt32.max % count
        while true {
            var value: UInt32 = 0
            let status = withUnsafeMutableBytes(of: &value) {
                SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
            }
            // 失敗することは実質ないが、その場合も OS の暗号論的に安全な乱数(SystemRandomNumberGenerator)で作る
            guard status == errSecSuccess else { return Int.random(in: range) }
            if value < limit {
                return range.lowerBound + Int(value % count)
            }
        }
    }
}
