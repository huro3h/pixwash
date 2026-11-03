import CoreGraphics
import UniformTypeIdentifiers

/// 指でなぞった1本の線。座標と太さは「画像の長辺 = 1」の単位で持つ。
/// 画面の表示サイズにも書き出し時の元画像サイズにも、長辺を掛けるだけで同じ線になる。
nonisolated struct MosaicStroke: Equatable, Sendable {
    var points: [CGPoint]
    var width: CGFloat
    /// なぞったときの隠し方(モザイク/ぼかしと強さ)。あとで設定を変えても、引いた線は変わらない
    var effect: ConcealEffect

    /// `unit`(描く先の長辺)に合わせて線を描く。色はあらかじめ呼び出し側で設定しておく。
    /// 座標は左上が原点の前提(SwiftUI の Canvas と同じ向き)。
    func draw(in context: CGContext, unit: CGFloat) {
        let scaled = points.map { CGPoint(x: $0.x * unit, y: $0.y * unit) }
        let lineWidth = width * unit
        guard let first = scaled.first else { return }
        if scaled.count == 1 {
            // 長さ 0 の線は環境によって点が描かれないことがあるので、円で塗る
            context.fillEllipse(in: CGRect(x: first.x - lineWidth / 2, y: first.y - lineWidth / 2,
                                           width: lineWidth, height: lineWidth))
        } else {
            context.setLineWidth(lineWidth)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addLines(between: scaled)
            context.strokePath()
        }
    }
}

nonisolated enum ConcealKind: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
    case mosaic, blur

    var id: Self { self }

    var label: String {
        switch self {
        case .mosaic: "モザイク"
        case .blur: "ぼかし"
        }
    }
}

/// なぞった部分の隠し方。
nonisolated struct ConcealEffect: Hashable, Sendable {
    var kind: ConcealKind
    /// 強さを画像の長辺に対する割合で表したもの(モザイクはブロック1つの大きさ、ぼかしは半径)。
    /// 割合なので、表示用の縮小画像と元画像で見た目が揃う
    var fraction: CGFloat
}

/// 隠し方が同じで続いている線のまとまり。隠し方ごとに1枚の加工済み画像を、まとまりの線の形で切り抜いて重ねる。
/// 隠し方だけでまとめず「続いている」ものに限るのは、重なったときに後から引いた線を上にするため。
nonisolated struct MosaicRun: Identifiable, Sendable {
    let id: Int
    let effect: ConcealEffect
    var strokes: [MosaicStroke]

    static func runs(of strokes: [MosaicStroke]) -> [MosaicRun] {
        var runs: [MosaicRun] = []
        for (index, stroke) in strokes.enumerated() {
            if let last = runs.indices.last, runs[last].effect == stroke.effect {
                runs[last].strokes.append(stroke)
            } else {
                runs.append(MosaicRun(id: index, effect: stroke.effect, strokes: [stroke]))
            }
        }
        return runs
    }
}

nonisolated struct PixelSize: Equatable, Sendable {
    var width: Int
    var height: Int

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    init(_ image: CGImage) {
        self.init(width: image.width, height: image.height)
    }

    var longEdge: Int { max(width, height) }

    func scaled(by factor: Double) -> PixelSize {
        PixelSize(width: max(1, Int((Double(width) * factor).rounded())),
                  height: max(1, Int((Double(height) * factor).rounded())))
    }

    var label: String { "\(width) × \(height)" }
}

nonisolated enum ResizeMode: String, CaseIterable, Identifiable, Codable, Sendable {
    // 並び順がそのまま画面の切り替えの順になる。よく使う長辺を真ん中に置く
    case original, longEdge, percent

    var id: Self { self }

    var label: String {
        switch self {
        case .original: "元のまま"
        case .longEdge: "長辺"
        case .percent: "割合"
        }
    }
}

nonisolated enum OutputFormat: String, CaseIterable, Identifiable, Sendable {
    case jpeg, png

    var id: Self { self }

    var label: String {
        switch self {
        case .jpeg: "JPEG"
        case .png: "PNG"
        }
    }

    var utType: UTType {
        switch self {
        case .jpeg: .jpeg
        case .png: .png
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .png: "png"
        }
    }

    /// HDR のゲインマップを入れられるか(PNG は入れられない)
    var supportsGainMap: Bool { self == .jpeg }
}

/// 書き出しの設定(サイズ・形式・メタデータ)。
nonisolated struct ExportSettings: Equatable, Sendable {
    /// 既定は長辺 1920px(ユーザーの希望、2026-11-03)
    var resizeMode: ResizeMode = .longEdge
    var percent: Double = 50
    var longEdge: Int = 1920
    var format: OutputFormat = .jpeg
    var jpegQuality: Double = 0.9
    var stripMetadata = true
    /// 元の写真が HDR なら、HDR のまま書き出す(ゲインマップを作り直して付ける)
    var keepsHDR = true

    /// 書き出すピクセル数。長辺指定は拡大しない(元より大きい値なら元のまま)。
    func outputSize(for size: PixelSize) -> PixelSize {
        switch resizeMode {
        case .original:
            return size
        case .percent:
            return size.scaled(by: percent / 100)
        case .longEdge:
            guard longEdge > 0, longEdge < size.longEdge else { return size }
            return size.scaled(by: Double(longEdge) / Double(size.longEdge))
        }
    }
}

/// 書き出し結果を使い回してよいかの判定に使う。これが同じなら同じ画像になる。
nonisolated struct ExportKey: Equatable, Sendable {
    var strokes: [MosaicStroke]
    var settings: ExportSettings
}
