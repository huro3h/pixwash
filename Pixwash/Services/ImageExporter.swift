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

    /// 縮小してからモザイクをかける(HDR の画像は1画素が普通の倍のメモリを使うので、元の大きさで合成しない)。
    /// モザイクの粗さ・線の太さは長辺に対する割合なので、順番を変えても見た目はほぼ同じ。
    @concurrent
    static func export(_ photo: LoadedPhoto, key: ExportKey) async throws -> ExportResult {
        let target = key.settings.outputSize(for: photo.size)
        // 普通の画像(SDR)は、元の写真に入っているものを使う(カメラが鮮やかさなどを仕上げたもの)
        let sdr = try edited(photo.full, to: target, strokes: key.strokes)
        let keepsHDR = key.settings.keepsHDR && photo.hasHDR && key.settings.format.supportsGainMap
        let data: Data
        if keepsHDR, let decoded = ImageDecoder.hdrImage(photo.data, maxPixelSize: target.longEdge) {
            // HDR の画像にも同じ縮小・モザイクをかけ、普通の画像との比からゲインマップを作る
            let hdr = try edited(decoded, to: target, strokes: key.strokes)
            data = try encodeHDR(sdr: sdr, hdr: hdr, settings: key.settings, sourceData: photo.data)
        } else {
            data = try encode(sdr, settings: key.settings, sourceData: photo.data)
        }
        let url = try write(data, fileExtension: key.settings.format.fileExtension)
        return ExportResult(data: data, size: PixelSize(sdr), fileURL: url)
    }

    private static func edited(_ image: CGImage, to target: PixelSize, strokes: [MosaicStroke]) throws -> CGImage {
        var image = image
        if target != PixelSize(image) {
            guard let resized = resize(image, to: target) else { throw Failure.renderFailed }
            image = resized
        }
        if !strokes.isEmpty {
            guard let composed = compose(base: image, strokes: strokes) else { throw Failure.renderFailed }
            image = composed
        }
        return image
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
        // HDR は 1.0 を超える明るさを保つため、16bit 浮動小数で作る
        let concealed = ciContext.createCGImage(output, from: input.extent, format: isHDR(image) ? .RGBAh : .RGBA8,
                                                colorSpace: drawableColorSpace(of: image))
        return concealed.map { preservingHeadroom(of: image, in: $0) }
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
        return context.makeImage().map { preservingHeadroom(of: base, in: $0) }
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
        return context.makeImage().map { preservingHeadroom(of: image, in: $0) }
    }

    private static func makeContext(width: Int, height: Int, like image: CGImage) -> CGContext? {
        if isHDR(image) {
            // 1.0 を超える値を切り捨てない、16bit 浮動小数・拡張範囲の色空間で描く
            return CGContext(data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: 0,
                             space: drawableColorSpace(of: image),
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                 | CGBitmapInfo.floatComponents.rawValue
                                 | CGImageByteOrderInfo.order16Little.rawValue)
        }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: drawableColorSpace(of: image),
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// 写真の色空間(Display P3 など)を保つ。RGB 以外(グレースケール・パレット)は sRGB に寄せる。
    /// HDR は拡張範囲の Display P3(線形)で扱う
    private static func drawableColorSpace(of image: CGImage) -> CGColorSpace {
        if isHDR(image) {
            return CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        }
        if let space = image.colorSpace, space.model == .rgb, space.supportsOutput {
            return space
        }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }

    /// HDR として読み込んだ画像か。`kCGImageSourceDecodeToHDR` で読むと PQ / HLG(ITU-R 2100)の色空間・10bit で返り、
    /// こちらで描き直したものは拡張範囲の色空間になる。どちらも 1.0 を超える明るさを持てる
    static func isHDR(_ image: CGImage) -> Bool {
        guard let space = image.colorSpace else { return false }
        return CGColorSpaceUsesExtendedRange(space) || CGColorSpaceUsesITUR_2100TF(space)
    }

    /// 描き直した画像には「どこまで明るいか」(headroom)が付かないので、元の画像の値を付け直す。
    /// 付いていないと、書き出すときにゲインマップの強さが決められない
    private static func preservingHeadroom(of source: CGImage, in image: CGImage) -> CGImage {
        let headroom = source.contentHeadroom
        guard isHDR(image), headroom >= 1 else { return image }
        return CGImageCreateCopyWithContentHeadroom(headroom, image) ?? image
    }

    // MARK: - エンコード

    private static func encode(_ image: CGImage, settings: ExportSettings, sourceData: Data) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, settings.format.utType.identifier as CFString, 1, nil
        ) else { throw Failure.encodeFailed }

        var properties = metadata(for: image, settings: settings, sourceData: sourceData)
        if settings.format == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = settings.jpegQuality
        }
        // 渡した辞書にない項目は書き込まれない(元の Exif・GPS・XMP は引き継がれない)
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encodeFailed }
        return output as Data
    }

    /// 普通の画像(SDR)に、HDR の画像との比から作ったゲインマップを付けて JPEG にする。
    /// 最初は `kCGImageDestinationEncodeToISOGainmap` で HDR の画像だけを渡していたが、普通の画像を ImageIO が作り直すため、
    /// 実際の写真で元より約3割暗く・淡くなった(HDR で見ても淡い)。普通の画像は元の写真のものを使うことにした(2026-11-03)
    private static func encodeHDR(sdr: CGImage, hdr: CGImage, settings: ExportSettings, sourceData: Data) throws -> Data {
        // CIImage の properties がそのままファイルのメタデータになる。ここで渡したもの以外は書かれない
        let properties = metadata(for: sdr, settings: settings, sourceData: sourceData)
        let base = CIImage(cgImage: sdr).settingProperties(properties as [AnyHashable: Any])
        let options: [CIImageRepresentationOption: Any] = [
            .hdrImage: CIImage(cgImage: hdr),
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): settings.jpegQuality,
        ]
        guard let colorSpace = sdr.colorSpace,
              let data = ciContext.jpegRepresentation(of: base, colorSpace: colorSpace, options: options) else {
            throw Failure.encodeFailed
        }
        return data
    }

    /// 書き込むメタデータ。削除する設定なら向き(常に「そのまま」)だけ
    private static func metadata(for image: CGImage, settings: ExportSettings, sourceData: Data) -> [CFString: Any] {
        var properties: [CFString: Any] = [:]
        if !settings.stripMetadata {
            properties = carriedMetadata(from: sourceData, size: PixelSize(image))
        }
        // 画素はすでに正しい向きに焼き込んであるので、向きは常に「そのまま」
        properties[kCGImagePropertyOrientation] = 1
        return properties
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
