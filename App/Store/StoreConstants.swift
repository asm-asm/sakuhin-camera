import Foundation

/// サブスクの商品ID。App Store Connect に同じIDで登録する。
enum ProductIDs {
    static let monthly = "com.sammy.sakuhincamera.premium.monthly"
    static let yearly = "com.sammy.sakuhincamera.premium.yearly"

    static let all: Set<String> = [monthly, yearly]
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
