import AppKit
import JamakCore
import SwiftUI

/// 색 토큰(설계 문서 2절). SwiftUI `Color`는 `Theme.bg0`처럼, AppKit `NSColor`는 `Theme.NS.bg0`처럼 쓴다.
enum Theme {
    // 배경
    static let bg0 = Color(hex: 0x121316)
    static let bg1 = Color(hex: 0x191A1E)
    static let bg2 = Color(hex: 0x202227)
    static let bg3 = Color(hex: 0x282A30)
    // 선
    static let line = Color(hex: 0x2C2F35)
    static let line2 = Color(hex: 0x383B42)
    // 글자
    static let text = Color(hex: 0xE9E7E2)
    static let text2 = Color(hex: 0xA3A5AC)
    static let text3 = Color(hex: 0x6E717A)
    // 강조: 재생 헤드, 선택 조각 테두리, 선택 구간, 주 버튼, 현재 탭 밑줄에만 쓴다.
    static let accent = Color(hex: 0xF2CC4E)
    static let accentInk = Color(hex: 0x1A1608)
    static let accentSoft = Color(hex: 0xF2CC4E).opacity(0.14)
    // 레인
    static let screen = Color(hex: 0x9B7BE6)
    static let speech = Color(hex: 0x4F8EF0)
    static let sound = Color(hex: 0xE3874F)
    /// 장면 메모 레인. 조각 종류 색, 표시 색과 겹치지 않는 분홍.
    static let memo = Color(hex: 0xD77BB6)
    // 표시
    static let suspect = Color(hex: 0xEF5A55)
    static let fixed = Color(hex: 0x3FB68B)
    /// 겹침(의심 아님) 빗금
    static let overlap = Color(hex: 0xB08F3A)
    /// 행·세그먼트 바깥 반경
    static let rowRadius: CGFloat = 7
    /// 배지 글자색(시안 .badge)
    static let suspectText = Color(hex: 0xFF8A85)
    static let fixedText = Color(hex: 0x6FD3AD)
    /// 경고(초당 글자 수가 기준을 넘음, 시안 .meta .warn)
    static let warning = Color(hex: 0xF0B35A)
    /// 비교에서 넣은 부분 글자색(시안 .diff ins)
    static let insertedText = Color(hex: 0x7EE0BA)

    static func color(_ kind: SubtitleKind) -> Color {
        switch kind {
        case .screen: screen
        case .speech: speech
        case .sound: sound
        }
    }

    /// 같은 토큰의 `NSColor` 판(타임라인 그리기용).
    enum NS {
        static let bg0 = NSColor(hex: 0x121316)
        static let bg1 = NSColor(hex: 0x191A1E)
        static let bg2 = NSColor(hex: 0x202227)
        static let bg3 = NSColor(hex: 0x282A30)
        static let line = NSColor(hex: 0x2C2F35)
        static let line2 = NSColor(hex: 0x383B42)
        static let text = NSColor(hex: 0xE9E7E2)
        static let text2 = NSColor(hex: 0xA3A5AC)
        static let text3 = NSColor(hex: 0x6E717A)
        static let accent = NSColor(hex: 0xF2CC4E)
        static let accentInk = NSColor(hex: 0x1A1608)
        static let screen = NSColor(hex: 0x9B7BE6)
        static let speech = NSColor(hex: 0x4F8EF0)
        static let sound = NSColor(hex: 0xE3874F)
        static let memo = NSColor(hex: 0xD77BB6)
        static let suspect = NSColor(hex: 0xEF5A55)
        static let fixed = NSColor(hex: 0x3FB68B)
        static let overlap = NSColor(hex: 0xB08F3A)

        static func color(_ kind: SubtitleKind) -> NSColor {
            switch kind {
            case .screen: screen
            case .speech: speech
            case .sound: sound
            }
        }
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

extension View {
    /// 패널 바탕: 단계 0~3이 bg0~bg3.
    func jPanel(_ level: Int) -> some View {
        background(level <= 0 ? Theme.bg0 : level == 1 ? Theme.bg1 : level == 2 ? Theme.bg2 : Theme.bg3)
    }
}
