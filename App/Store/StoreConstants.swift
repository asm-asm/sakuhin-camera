import Foundation

/// プレミアム（買い切り・非消耗型）の商品ID。App Store Connect に同じIDで登録する。
/// 以前作ったサブスク（premium.monthly / premium.yearly）は使わない（審査にも出していない）。
enum ProductIDs {
    static let premium = "com.sammy.sakuhincamera.premium.lifetime"

    static let all: Set<String> = [premium]
}

enum AppLinks {
    /// 利用規約（Apple 標準の使用許諾契約）。
    static let termsOfUse = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
}

enum AppText {
    static let captionBase = "作品は無加工・背景は差し替え"

    static func caption(aiGeneratedBackground: Bool) -> String {
        aiGeneratedBackground ? "\(captionBase)（AI生成背景）" : captionBase
    }
}
