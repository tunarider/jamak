import AppKit
import SwiftUI

/// 시안의 `.btn`: 높이 28, 반경 6. 눌림·마우스 올림은 bg2/bg3, 비활성은 불투명도 0.45.
struct JButtonStyle: ButtonStyle {
    enum Role { case primary, secondary, ghost, icon }
    var role: Role = .secondary
    /// 켜진 상태(시안 .btn.on)
    var isOn = false
    /// 높이. 상태 표시줄처럼 좁은 곳은 20(글자 11).
    var height: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        ButtonBody(configuration: configuration, role: role, isOn: isOn, height: height)
    }

    fileprivate struct ButtonBody: View {
        let configuration: Configuration
        let role: Role
        let isOn: Bool
        let height: CGFloat
        @State private var isHovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let pressed = isEnabled && configuration.isPressed
            configuration.label
                .font(.system(size: height < 28 ? 11 : 12, weight: role == .primary ? .semibold : .regular))
                .foregroundStyle(foreground)
                .padding(.horizontal, role == .icon ? 0 : height < 28 ? 8 : 11)
                .frame(width: role == .icon ? 30 : nil, height: height)
                .background(background(pressed: pressed), in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(border, lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { isHovering = $0 }
        }

        private var foreground: Color {
            switch role {
            case .primary: Theme.accentInk
            case .secondary: Theme.text
            case .ghost, .icon: isOn || (isEnabled && (isHovering || configuration.isPressed)) ? Theme.text : Theme.text2
            }
        }

        private func background(pressed: Bool) -> Color {
            switch role {
            case .primary:
                return Theme.accent.opacity(pressed ? 0.8 : (isEnabled && isHovering) ? 0.92 : 1)
            case .secondary:
                return pressed ? Theme.bg3 : (isEnabled && isHovering) || isOn ? Theme.bg3 : Theme.bg2
            case .ghost, .icon:
                return pressed ? Theme.bg3 : isOn ? Theme.bg3 : (isEnabled && isHovering) ? Theme.bg2 : .clear
            }
        }

        private var border: Color {
            switch role {
            case .primary: Theme.accent
            case .secondary: Theme.line2
            case .ghost, .icon: .clear
            }
        }
    }
}

extension ButtonStyle where Self == JButtonStyle {
    static var jPrimary: JButtonStyle { JButtonStyle(role: .primary) }
    static var jSecondary: JButtonStyle { JButtonStyle(role: .secondary) }
    static var jGhost: JButtonStyle { JButtonStyle(role: .ghost) }
    static var jIcon: JButtonStyle { JButtonStyle(role: .icon) }
    /// 켜짐 표시가 있는 유령/아이콘 버튼(시안 .btn.on)
    static func jGhost(isOn: Bool) -> JButtonStyle { JButtonStyle(role: .ghost, isOn: isOn) }
    static func jIcon(isOn: Bool) -> JButtonStyle { JButtonStyle(role: .icon, isOn: isOn) }
    /// 높이 20의 작은 보조 버튼(상태 표시줄 [취소]).
    static var jCompact: JButtonStyle { JButtonStyle(role: .secondary, height: 20) }
}

/// 메뉴 항목: 제목과 누를 때 할 일.
typealias JMenuItem = (title: String, action: () -> Void)

/// 비활성·도움말이 있는 메뉴 항목(`JMenuAnchor`로 띄운다).
struct JMenuEntry {
    var title: String
    var isEnabled = true
    /// 마우스를 올렸을 때 보일 도움말.
    var help: String?
    var action: () -> Void
}

/// Theme 버튼 모양의 메뉴 버튼. 누르면 버튼 아래에 메뉴가 뜬다(macOS 기본 팝업 버튼 모양을 쓰지 않는다).
struct JMenuButton<Label: View>: View {
    typealias Item = JMenuItem

    var style: JButtonStyle = .jSecondary
    let items: () -> [Item]
    @ViewBuilder let label: () -> Label
    @State private var anchor = JMenuAnchor.Anchor()

    init(style: JButtonStyle = .jSecondary, items: @escaping () -> [Item], @ViewBuilder label: @escaping () -> Label) {
        self.style = style
        self.items = items
        self.label = label
    }

    var body: some View {
        Button {
            anchor.popUp(items().map { JMenuEntry(title: $0.title, action: $0.action) })
        } label: {
            HStack(spacing: 4) {
                label()
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
        }
        .buttonStyle(style)
        .background(JMenuAnchor(anchor: anchor))
    }
}

extension JMenuButton where Label == Text {
    init(_ title: String, style: JButtonStyle = .jSecondary, items: @escaping () -> [Item]) {
        self.init(style: style, items: items) { Text(title) }
    }
}

/// 메뉴를 띄울 자리(버튼 뒤의 빈 NSView). 버튼에 `.background(JMenuAnchor(anchor:))`로 붙이고
/// 누를 때 `anchor.popUp(_:)`을 부르면 버튼 아래에 메뉴가 뜬다.
struct JMenuAnchor: NSViewRepresentable {
    @MainActor final class Anchor {
        weak var view: NSView?

        func popUp(_ items: [JMenuEntry]) {
            guard let view, !items.isEmpty else { return }
            let menu = NSMenu()
            menu.autoenablesItems = false
            for item in items {
                let menuItem = ClosureMenuItem(title: item.title, action: item.action)
                menuItem.isEnabled = item.isEnabled
                menuItem.toolTip = item.help
                menu.addItem(menuItem)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
        }
    }

    let anchor: Anchor

    func makeNSView(context: Context) -> NSView {
        let view = FlippedView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { anchor.view = nsView }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
}

/// 누르면 클로저를 부르는 메뉴 항목.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() { handler() }
}

/// 시안의 `.seg`: 반경 7 바깥 틀 안에 반경 5 항목. 아이콘만 있는 항목은 label을 `.help`로 쓴다.
struct JSegmented<T: Hashable>: View {
    typealias Item = (value: T, label: String, systemImage: String?)

    let items: [Item]
    @Binding var selection: T
    /// true면 아이콘이 있는 항목은 아이콘만 보인다.
    var iconOnly = false

    init(_ items: [Item], selection: Binding<T>, iconOnly: Bool = false) {
        self.items = items
        self._selection = selection
        self.iconOnly = iconOnly
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items.indices, id: \.self) { i in
                Cell(item: items[i], isSelected: items[i].value == selection, iconOnly: iconOnly) {
                    selection = items[i].value
                }
            }
        }
        .padding(2)
        .background(Theme.bg2, in: RoundedRectangle(cornerRadius: Theme.rowRadius))
        .overlay { RoundedRectangle(cornerRadius: Theme.rowRadius).strokeBorder(Theme.line, lineWidth: 1) }
    }

    private struct Cell: View {
        let item: Item
        let isSelected: Bool
        let iconOnly: Bool
        let action: () -> Void
        @State private var isHovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let showsLabel = !(iconOnly && item.systemImage != nil)
            Button(action: action) {
                HStack(spacing: 4) {
                    if let icon = item.systemImage { Image(systemName: icon) }
                    if showsLabel { Text(item.label) }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(isSelected || isHovering ? Theme.text : Theme.text2)
                .padding(.horizontal, showsLabel ? 9 : 7)
                .padding(.vertical, 3)
                .background(isSelected ? Theme.bg3 : isHovering ? Theme.bg3.opacity(0.5) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .contentShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help(showsLabel ? "" : item.label)
            .accessibilityLabel(item.label)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .opacity(isEnabled ? 1 : 0.45)
        }
    }
}

/// 필터 칩(시안 .chip). 선택되면 bg3 바탕에 line2 테두리.
struct JChip: View {
    let title: String
    var isOn: Bool
    var action: () -> Void
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(isOn || isHovering ? Theme.text : Theme.text2)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(isOn || isHovering ? Theme.bg3 : Theme.bg2, in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(isOn ? Theme.line2 : .clear, lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// 숫자·상태 배지(시안 .badge).
struct JBadge: View {
    enum Kind { case suspect, fixed, neutral, lock }
    var kind: Kind
    var count: Int?

    static func suspect(_ count: Int) -> JBadge { JBadge(kind: .suspect, count: count) }
    static func fixed(_ count: Int) -> JBadge { JBadge(kind: .fixed, count: count) }
    static func neutral(_ count: Int) -> JBadge { JBadge(kind: .neutral, count: count) }
    static var lock: JBadge { JBadge(kind: .lock, count: nil) }

    var body: some View {
        HStack(spacing: 3) {
            if kind == .lock {
                Image(systemName: "lock.fill").font(.system(size: 9))
                Text("잠김")
            } else if let count {
                Text("\(count)").monospacedDigit()
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(foreground)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(background, in: Capsule())
    }

    private var foreground: Color {
        switch kind {
        case .suspect: Theme.suspectText
        case .fixed: Theme.fixedText
        case .neutral, .lock: Theme.text2
        }
    }

    private var background: Color {
        switch kind {
        case .suspect: Theme.suspect.opacity(0.16)
        case .fixed: Theme.fixed.opacity(0.14)
        case .neutral, .lock: Theme.bg3
        }
    }
}

/// bg2 바탕, line2 테두리, 반경 9. `title`이 있으면 머리 줄(굵게, 오른쪽 보조 글자)과 구분선이 붙는다.
struct JCard<Content: View>: View {
    var title: String?
    var trailing: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                    Spacer(minLength: 0)
                    if let trailing {
                        Text(trailing).font(.system(size: 11)).foregroundStyle(Theme.text3)
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                Rectangle().fill(Theme.line).frame(height: 1)
            }
            content()
                .padding(.horizontal, 11)
                .padding(.top, 10)
                .padding(.bottom, 11)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg2, in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.line2, lineWidth: 1) }
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

#Preview("Jamak 스타일") {
    @Previewable @State var seg = 1
    @Previewable @State var iconSeg = "a"
    @Previewable @State var chip = true
    VStack(alignment: .leading, spacing: 14) {
        HStack {
            Button("주 버튼") {}.buttonStyle(.jPrimary)
            Button("보조 버튼") {}.buttonStyle(.jSecondary)
            Button("유령 버튼") {}.buttonStyle(.jGhost)
            Button { } label: { Image(systemName: "gearshape") }.buttonStyle(.jIcon).help("설정")
            Button("비활성") {}.buttonStyle(.jSecondary).disabled(true)
        }
        JSegmented([(1, "원문", nil), (2, "번역", nil), (3, "겹쳐 보기", "square.on.square")], selection: $seg)
        JSegmented([("a", "목록", "list.bullet"), ("b", "격자", "square.grid.2x2")], selection: $iconSeg, iconOnly: true)
        HStack {
            JChip(title: "전체", isOn: chip) { chip.toggle() }
            JChip(title: "의심", isOn: !chip) { chip.toggle() }
        }
        HStack {
            JBadge.suspect(3); JBadge.fixed(12); JBadge.neutral(48); JBadge.lock
        }
        JCard(title: "의심 조각", trailing: "1/3") { Text("본문").foregroundStyle(Theme.text2) }
            .frame(width: 260)
        Text("패널").foregroundStyle(Theme.text).padding().jPanel(1)
    }
    .padding(20)
    .frame(width: 520)
    .jPanel(0)
}
