import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// 塗りの操作。位置は拡大前の表示上の座標(`contentSize` の中)
enum DrawEvent {
    case began(CGPoint, zoomScale: CGFloat)
    case moved(CGPoint, zoomScale: CGFloat)
    case ended
    case cancelled
}

/// 1本指で塗り、2本指で拡大・移動できる表示領域。
/// SwiftUI のジェスチャでは触れている指の本数を区別できないので、UIScrollView に SwiftUI の中身を載せている。
/// 移動(パン)は2本指のときだけ効くようにし、塗りは指1本のときだけ反応する `SingleTouchGestureRecognizer` で受ける。
struct ZoomableCanvas<Content: View>: UIViewRepresentable {
    /// 拡大前の中身の大きさ(写真を表示領域に収めた大きさ)
    let contentSize: CGSize
    let content: Content
    let isDrawingEnabled: Bool
    /// 増えるたびに全体表示へ戻す
    let resetZoomRequest: Int
    @Binding var zoomScale: CGFloat
    let onDraw: (DrawEvent) -> Void

    static var maximumZoomScale: CGFloat { 8 }

    func makeCoordinator() -> Coordinator {
        Coordinator(rootView: content)
    }

    func makeUIView(context: Context) -> CenteringScrollView {
        let coordinator = context.coordinator
        let scrollView = CenteringScrollView()
        scrollView.delegate = coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = Self.maximumZoomScale
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        // 2本指の移動かどうかを待たずに、1本指の塗りをすぐ始める
        scrollView.delaysContentTouches = false
        scrollView.backgroundColor = .clear

        let hosted = coordinator.host.view!
        hosted.backgroundColor = .clear
        scrollView.addSubview(hosted)

        let draw = SingleTouchGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleDraw(_:)))
        draw.delegate = coordinator
        hosted.addGestureRecognizer(draw)
        coordinator.drawRecognizer = draw
        return scrollView
    }

    func updateUIView(_ scrollView: CenteringScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.host.rootView = content
        coordinator.drawRecognizer?.isEnabled = isDrawingEnabled
        // 塗らないタブを開いている間は、1本指でも移動できる
        scrollView.panGestureRecognizer.minimumNumberOfTouches = isDrawingEnabled ? 2 : 1

        if coordinator.contentSize != contentSize {
            coordinator.contentSize = contentSize
            scrollView.setZoomScale(1, animated: false)
            coordinator.host.view.frame = CGRect(origin: .zero, size: contentSize)
            scrollView.contentSize = contentSize
            scrollView.setNeedsLayout()
        }
        if coordinator.resetZoomRequest != resetZoomRequest {
            coordinator.resetZoomRequest = resetZoomRequest
            scrollView.setZoomScale(1, animated: true)
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        let host: UIHostingController<Content>
        var parent: ZoomableCanvas?
        var drawRecognizer: SingleTouchGestureRecognizer?
        var contentSize: CGSize = .zero
        var resetZoomRequest = 0
        private weak var scrollView: UIScrollView?

        init(rootView: Content) {
            host = UIHostingController(rootView: rootView)
            // 中身の大きさはこちらで決める。安全領域の余白も付けない
            host.sizingOptions = []
            host.safeAreaRegions = []
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            self.scrollView = scrollView
            return host.view
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let scale = scrollView.zoomScale
            // updateUIView の中の setZoomScale からも呼ばれるので、SwiftUI の状態は次の周回で変える
            DispatchQueue.main.async { [weak self] in
                guard let parent = self?.parent, abs(parent.zoomScale - scale) > 0.001 else { return }
                parent.zoomScale = scale
            }
        }

        @objc func handleDraw(_ recognizer: SingleTouchGestureRecognizer) {
            guard let parent else { return }
            // 拡大中も、ビュー自身の座標(拡大前の大きさ)で位置が取れる
            let location = recognizer.location(in: host.view)
            let scale = (host.view.superview as? UIScrollView)?.zoomScale ?? 1
            switch recognizer.state {
            case .began: parent.onDraw(.began(location, zoomScale: scale))
            case .changed: parent.onDraw(.moved(location, zoomScale: scale))
            case .ended: parent.onDraw(.ended)
            case .cancelled, .failed: parent.onDraw(.cancelled)
            default: break
            }
        }

        // 塗りの最中に2本目の指が触れたら、拡大・移動もすぐ始められるようにする
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

/// 拡大していないとき(中身が表示領域より小さいとき)に、中身を真ん中に置く UIScrollView。
final class CenteringScrollView: UIScrollView {
    override func layoutSubviews() {
        super.layoutSubviews()
        let horizontal = max((bounds.width - contentSize.width) / 2, 0)
        let vertical = max((bounds.height - contentSize.height) / 2, 0)
        let inset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        if contentInset != inset {
            contentInset = inset
        }
        // 全体表示のときは位置を固定する(余白を付けただけでは左上に寄ったままになるため)
        if zoomScale <= minimumZoomScale, !isZooming, !isZoomBouncing, !isDragging, !isDecelerating {
            let offset = CGPoint(x: -inset.left, y: -inset.top)
            if contentOffset != offset {
                contentOffset = offset
            }
        }
    }
}

/// 指が1本だけのときに塗りとして認識する。2本目の指が触れたら取り消す(拡大・移動に譲る)。
/// UIPanGestureRecognizer は動き出すまで少し待つので、触れた瞬間から線を引けるよう自前で作っている。
final class SingleTouchGestureRecognizer: UIGestureRecognizer {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if (event.allTouches?.count ?? touches.count) > 1 {
            state = state == .possible ? .failed : .cancelled
            return
        }
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .began || state == .changed else { return }
        if (event.allTouches?.count ?? 1) > 1 {
            state = .cancelled
        } else {
            state = .changed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .began || state == .changed {
            state = .ended
        } else {
            state = .failed
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .cancelled
    }
}
