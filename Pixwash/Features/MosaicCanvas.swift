import SwiftUI

/// 写真を表示し、指でなぞった部分にモザイク/ぼかしの画像を重ねる。なぞっている間はペンの線を出し、指を離すと反映する。
/// 1本指で塗り、2本指で拡大・移動する(`ZoomableCanvas`)。
struct MosaicCanvas: View {
    let image: CGImage
    /// 隠し方ごとの加工済み画像
    let concealed: [ConcealEffect: CGImage]
    @Binding var strokes: [MosaicStroke]
    /// ペンの太さ(画面上の pt)
    let brushSize: CGFloat
    /// これからなぞる線の隠し方
    let effect: ConcealEffect
    let isDrawingEnabled: Bool

    @State private var current: MosaicStroke?
    @State private var zoomScale: CGFloat = 1
    @State private var resetZoomRequest = 0

    var body: some View {
        GeometryReader { geometry in
            let size = fittedSize(in: geometry.size)
            let unit = max(size.width, size.height)
            ZoomableCanvas(
                contentSize: size,
                content: CanvasLayers(image: image, concealed: concealed, strokes: strokes, current: current, unit: unit),
                isDrawingEnabled: isDrawingEnabled,
                resetZoomRequest: resetZoomRequest,
                zoomScale: $zoomScale
            ) { event in
                handle(event, unit: unit)
            }
            .overlay(alignment: .topTrailing) {
                if zoomScale > 1.01 {
                    Button("全体表示", systemImage: "arrow.down.right.and.arrow.up.left") {
                        resetZoomRequest += 1
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .background(.regularMaterial, in: .capsule)
                    .padding(8)
                }
            }
        }
    }

    private func fittedSize(in container: CGSize) -> CGSize {
        let scale = min(container.width / CGFloat(image.width), container.height / CGFloat(image.height))
        return CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
    }

    private func handle(_ event: DrawEvent, unit: CGFloat) {
        guard unit > 0 else { return }
        switch event {
        case let .began(location, zoomScale):
            // 太さは画面上の大きさで決める。拡大中に塗ると、写真に対しては細い線になる
            let point = CGPoint(x: location.x / unit, y: location.y / unit)
            current = MosaicStroke(points: [point], width: brushSize / zoomScale / unit, effect: effect)
        case let .moved(location, zoomScale):
            guard var stroke = current else { return }
            let point = CGPoint(x: location.x / unit, y: location.y / unit)
            // 指がほとんど動いていない間は点を増やさない(画面上で 1pt 未満)
            if let last = stroke.points.last, hypot(last.x - point.x, last.y - point.y) * unit * zoomScale < 1 { return }
            stroke.points.append(point)
            current = stroke
        case .ended:
            if let current {
                strokes.append(current)
            }
            current = nil
        case .cancelled:
            // 2本目の指が触れたら(拡大・移動を始めたら)、塗りかけの線は捨てる
            current = nil
        }
    }
}

/// 写真・加工済みの画像・塗っている途中のペンの線を重ねたもの。
/// 表示中は合成画像を作らず、加工済みの画像を線の形のマスクで切り抜いて重ねるだけにしている(なぞる間も軽い)。
private struct CanvasLayers: View {
    let image: CGImage
    let concealed: [ConcealEffect: CGImage]
    let strokes: [MosaicStroke]
    let current: MosaicStroke?
    let unit: CGFloat

    var body: some View {
        ZStack {
            Image(decorative: image, scale: 1)
                .resizable()
            ForEach(MosaicRun.runs(of: strokes)) { run in
                if let mosaic = concealed[run.effect] {
                    Image(decorative: mosaic, scale: 1)
                        .resizable()
                        .mask {
                            Canvas { context, _ in
                                context.withCGContext { cgContext in
                                    cgContext.setFillColor(gray: 0, alpha: 1)
                                    cgContext.setStrokeColor(gray: 0, alpha: 1)
                                    for stroke in run.strokes {
                                        stroke.draw(in: cgContext, unit: unit)
                                    }
                                }
                            }
                        }
                }
            }
            // なぞっている間は半透明のペンの線だけ出し、指を離したときにモザイクへ変える
            if let current {
                Canvas { context, _ in
                    context.withCGContext { cgContext in
                        cgContext.setAlpha(0.5)
                        cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
                        cgContext.setFillColor(UIColor.systemYellow.cgColor)
                        cgContext.setStrokeColor(UIColor.systemYellow.cgColor)
                        current.draw(in: cgContext, unit: unit)
                        cgContext.endTransparencyLayer()
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}
