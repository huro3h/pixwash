import Foundation

/// 最後に使った設定。変えるたびに保存し、次にアプリを開いたときの初期値にする(ユーザーの希望、2026-11-03)。
/// 形式(JPEG / PNG)は写真に合わせて選び直すので保存しない。
nonisolated struct EditorPreferences: Codable, Sendable {
    var concealKind: ConcealKind = .mosaic
    var strength: Double = 0.3
    var brushSize: Double = 28
    var resizeMode: ResizeMode = .longEdge
    var percent: Double = 50
    var longEdge: Int = 1920
    var jpegQuality: Double = 0.9
    var stripMetadata = true
    var keepsHDR = true

    private static let key = "editorPreferences"

    init() {}

    /// 項目を足し引きしても、保存してある残りの項目は生かす(1つ読めないだけで全部が初期値に戻らないように)
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = EditorPreferences()
        concealKind = (try? container.decode(ConcealKind.self, forKey: .concealKind)) ?? defaults.concealKind
        strength = (try? container.decode(Double.self, forKey: .strength)) ?? defaults.strength
        brushSize = (try? container.decode(Double.self, forKey: .brushSize)) ?? defaults.brushSize
        resizeMode = (try? container.decode(ResizeMode.self, forKey: .resizeMode)) ?? defaults.resizeMode
        percent = (try? container.decode(Double.self, forKey: .percent)) ?? defaults.percent
        longEdge = (try? container.decode(Int.self, forKey: .longEdge)) ?? defaults.longEdge
        jpegQuality = (try? container.decode(Double.self, forKey: .jpegQuality)) ?? defaults.jpegQuality
        stripMetadata = (try? container.decode(Bool.self, forKey: .stripMetadata)) ?? defaults.stripMetadata
        keepsHDR = (try? container.decode(Bool.self, forKey: .keepsHDR)) ?? defaults.keepsHDR
    }

    static func load() -> EditorPreferences {
        guard let data = UserDefaults.standard.data(forKey: key),
              let preferences = try? JSONDecoder().decode(EditorPreferences.self, from: data) else {
            return EditorPreferences()
        }
        return preferences
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
