import CoreGraphics
import Foundation
import Observation

/// 編集の状態。写真を選ぶ前から画面を出すので、写真は後から入る。
/// 写真を選び直すと線などは消えるが、隠し方・サイズなどの設定は引き継ぐ。
/// 設定は変えるたびに保存し、次にアプリを開いたときも使う(`EditorPreferences`)。
@Observable
final class EditorModel {
    private(set) var photo: LoadedPhoto?
    var strokes: [MosaicStroke] = []
    /// これからなぞる線の隠し方と強さ(0〜1)。実際の大きさは `effect`
    var concealKind: ConcealKind { didSet { savePreferences() } }
    var strength: Double { didSet { savePreferences() } }
    /// ペンの太さ(画面上の pt)
    var brushSize: Double { didSet { savePreferences() } }
    var settings: ExportSettings { didSet { savePreferences() } }

    init() {
        let preferences = EditorPreferences.load()
        concealKind = preferences.concealKind
        strength = preferences.strength
        brushSize = preferences.brushSize
        var settings = ExportSettings()
        settings.resizeMode = preferences.resizeMode
        settings.percent = preferences.percent
        settings.longEdge = preferences.longEdge
        settings.jpegQuality = preferences.jpegQuality
        settings.stripMetadata = preferences.stripMetadata
        settings.keepsHDR = preferences.keepsHDR
        self.settings = settings
    }

    private func savePreferences() {
        var preferences = EditorPreferences()
        preferences.concealKind = concealKind
        preferences.strength = strength
        preferences.brushSize = brushSize
        preferences.resizeMode = settings.resizeMode
        preferences.percent = settings.percent
        preferences.longEdge = settings.longEdge
        preferences.jpegQuality = settings.jpegQuality
        preferences.stripMetadata = settings.stripMetadata
        preferences.keepsHDR = settings.keepsHDR
        preferences.save()
    }

    /// 表示用の加工済み画像。隠し方(`effect`)ごとに作って持っておく
    private(set) var concealedPreviews: [ConcealEffect: CGImage] = [:]
    private(set) var exported: (key: ExportKey, result: ExportResult)?

    func open(_ photo: LoadedPhoto) {
        ImageExporter.clearExportDirectory()
        self.photo = photo
        strokes = []
        concealedPreviews = [:]
        exported = nil
        // 透過のある PNG を JPEG にすると透明部分が黒くなるので、PNG は PNG のまま出す
        settings.format = photo.type?.conforms(to: .png) == true ? .png : .jpeg
    }

    /// 長辺に対する割合。4032px の写真なら、モザイクはブロック1つが約 80〜240px、ぼかしは半径が約 40〜160px。
    /// モザイクの下限は 0.008 → 0.015 → 0.03(細かいのは要らない)→ 0.02(少し細かいのも欲しい)と調整した(2026-11-03)
    var effect: ConcealEffect {
        switch concealKind {
        case .mosaic: ConcealEffect(kind: .mosaic, fraction: 0.02 + 0.04 * strength)
        case .blur: ConcealEffect(kind: .blur, fraction: 0.01 + 0.03 * strength)
        }
    }

    var exportKey: ExportKey {
        ExportKey(strokes: strokes, settings: settings)
    }

    /// いまの設定で書き出した結果(設定を変えて書き出し直す前は nil)
    var currentResult: ExportResult? {
        guard let exported, exported.key == exportKey else { return nil }
        return exported.result
    }

    var outputSize: PixelSize? { photo.map { settings.outputSize(for: $0.size) } }

    /// いまの隠し方の画像を先に作っておく(指を離したときにすぐ反映するため)
    func prepareConcealedPreview() async {
        let effect = effect
        guard let photo, concealedPreviews[effect] == nil else { return }
        let image = await ImageExporter.concealed(photo.preview, effect: effect)
        // 作っている間に写真が選び直されていたら捨てる
        guard self.photo?.id == photo.id else { return }
        concealedPreviews[effect] = image
    }

    @discardableResult
    func export() async throws -> ExportResult {
        guard let photo else { throw ImageDecoder.Failure.unreadable }
        let key = exportKey
        if let exported, exported.key == key { return exported.result }
        let result = try await ImageExporter.export(photo, key: key)
        guard self.photo?.id == photo.id else { throw CancellationError() }
        if let old = exported?.result.fileURL {
            try? FileManager.default.removeItem(at: old)
        }
        exported = (key, result)
        return result
    }
}
