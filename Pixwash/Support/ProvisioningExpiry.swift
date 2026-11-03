import SwiftUI

/// 無料の Apple ID(Personal Team)で入れたアプリは、署名のプロファイルが7日で切れると起動できなくなる。
/// アプリに同梱されるプロファイル(embedded.mobileprovision)から期限を読む。
/// (aozora と pixwash に同じものを置いている。直すときは両方直す)
enum ProvisioningExpiry {
    /// シミュレータ・App Store 版にはプロファイルが同梱されないので nil
    static let date: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              // 署名(CMS)で包まれているが、中の plist は平文のまま入っている
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil
              ) as? [String: Any] else { return nil }
        return plist["ExpirationDate"] as? Date
    }()
}

/// ヘッダーの真ん中に小さく2行で出す。1行目が期限の日時「11/10 22:05」、2行目が残り「6日23時間」。
/// 自分が分かればよいので「期限」などの言葉は付けない(ユーザーの希望、2026-11-03)。残りが少なくなると色を変える
struct ProvisioningExpiryLabel: View {
    var body: some View {
        if let date = ProvisioningExpiry.date {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let remaining = date.timeIntervalSince(context.date)
                VStack(spacing: 0) {
                    Text(Self.dateFormatter.string(from: date))
                    Text(Self.remainingText(remaining))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(remaining < 86_400 ? AnyShapeStyle(.red)
                                 : remaining < 2 * 86_400 ? AnyShapeStyle(.orange)
                                 : AnyShapeStyle(.secondary))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("アプリの署名の期限")
        }
    }

    /// 端末の言語・地域の設定によっては「11/10, 10:05」(12時間表記で午前・午後なし)になるので、書式を固定する
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()

    private static func remainingText(_ remaining: TimeInterval) -> String {
        if remaining <= 0 { return "期限切れ" }
        let hours = Int(remaining / 3600)
        if hours < 24 { return "\(max(1, hours))時間" }
        return "\(hours / 24)日\(hours % 24)時間"
    }
}
