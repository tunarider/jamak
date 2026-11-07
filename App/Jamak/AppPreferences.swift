import Foundation
import JamakCore

/// 앱 전체 설정 중 여러 곳이 읽는 값.
enum AppPreferences {
    /// 설정 "내 언어"의 저장 키. 원문 티켓의 뜻 풀이에 쓰고, 나중에 화면 언어(i18n)에도 쓴다.
    static let userLanguageKey = "userLanguage"

    /// 처음 값: 시스템 언어가 한국어·일본어·영어 중 하나면 그것, 아니면 한국어.
    static var defaultUserLanguage: Language {
        Locale.preferredLanguages.lazy
            .compactMap { Locale(identifier: $0).language.languageCode?.identifier }
            .compactMap(Language.init(rawValue:)).first ?? .ko
    }

    /// 사용자가 아는 언어.
    static var userLanguage: Language {
        UserDefaults.standard.string(forKey: userLanguageKey).flatMap(Language.init(rawValue:)) ?? defaultUserLanguage
    }
}
