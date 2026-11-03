import Foundation
import ImageIO

/// 元画像に含まれるメタデータのうち、人に見せる価値のあるもの。
nonisolated struct PhotoMetadata: Sendable {
    nonisolated struct Item: Identifiable, Sendable {
        let label: String
        let value: String
        var id: String { label }
    }

    nonisolated struct Group: Identifiable, Sendable {
        let name: String
        let items: [Item]
        var id: String { name }
    }

    var takenAt: String?
    var camera: String?
    var lens: String?
    var software: String?
    var latitude: Double?
    var longitude: Double?
    /// 全項目(辞書ごと)。「すべての項目」に出す
    var groups: [Group] = []

    var hasLocation: Bool { latitude != nil && longitude != nil }

    init(properties: [CFString: Any]) {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

        if let date = exif[kCGImagePropertyExifDateTimeOriginal] as? String ?? tiff[kCGImagePropertyTIFFDateTime] as? String {
            // Exif の日時は「2026:11:03 12:34:56」の形
            let parts = date.split(separator: " ", maxSplits: 1)
            let day = parts.first.map { $0.replacingOccurrences(of: ":", with: "/") } ?? date
            let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String
            takenAt = ([day] + parts.dropFirst().map(String.init) + [offset].compactMap { $0 }).joined(separator: " ")
        }
        let make = tiff[kCGImagePropertyTIFFMake] as? String
        let model = tiff[kCGImagePropertyTIFFModel] as? String
        if let model {
            // 「Apple iPhone 17」のように重ならないよう、機種名にメーカー名が入っていれば足さない
            camera = make.map { model.hasPrefix($0) ? model : "\($0) \(model)" } ?? model
        } else {
            camera = make
        }
        lens = exif[kCGImagePropertyExifLensModel] as? String
        software = tiff[kCGImagePropertyTIFFSoftware] as? String

        if let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            latitude = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -lat : lat
            longitude = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -lon : lon
        }

        var general: [Item] = []
        var nested: [Group] = []
        for (key, value) in properties.sorted(by: { ($0.key as String) < ($1.key as String) }) {
            let name = (key as String).trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
            if let dictionary = value as? [CFString: Any] {
                let items = dictionary
                    .sorted { ($0.key as String) < ($1.key as String) }
                    .compactMap { k, v in Self.describe(v).map { Item(label: k as String, value: $0) } }
                if !items.isEmpty { nested.append(Group(name: name, items: items)) }
            } else if let text = Self.describe(value) {
                general.append(Item(label: name, value: text))
            }
        }
        groups = (general.isEmpty ? [] : [Group(name: "一般", items: general)]) + nested
    }

    private static func describe(_ value: Any) -> String? {
        switch value {
        case let text as String:
            return text
        case let number as NSNumber:
            return number.stringValue
        case let array as [Any]:
            let parts = array.compactMap(describe)
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        case is [CFString: Any]:
            return "(\((value as? [CFString: Any])?.count ?? 0) 項目)"
        default:
            // Data などのバイナリは中身を出しても読めないので省く
            return nil
        }
    }
}
