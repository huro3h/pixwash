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

/// ヘッダーの真ん中に小さく出す「期限 11/10・あと6日」。残りが少なくなると色を変える
struct ProvisioningExpiryLabel: View {
    var body: some View {
        if let date = ProvisioningExpiry.date {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let remaining = date.timeIntervalSince(context.date)
                Text("期限 \(date.formatted(.dateTime.month(.defaultDigits).day()))・\(Self.remainingText(remaining))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(remaining < 86_400 ? AnyShapeStyle(.red)
                                     : remaining < 2 * 86_400 ? AnyShapeStyle(.orange)
                                     : AnyShapeStyle(.secondary))
            }
            .accessibilityLabel("アプリの署名の期限")
        }
    }

    private static func remainingText(_ remaining: TimeInterval) -> String {
        if remaining <= 0 { return "期限切れ" }
        if remaining < 86_400 { return "あと\(max(1, Int(remaining / 3600)))時間" }
        return "あと\(Int(remaining / 86_400))日"
    }
}
