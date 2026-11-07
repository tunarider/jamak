import AppKit
import SwiftUI

/// 끌어서 크기를 바꾸는 분할 뷰. 분할선은 1px `line`이다(시스템 밝은 분할선을 쓰지 않는다).
/// 각 칸은 따로 NSHostingView에 담기니, 환경 값(모델 등)은 칸을 만들 때 넣어 준다.
struct JSplitView: NSViewRepresentable {
    struct Pane {
        /// 최소 크기(가로 분할이면 너비, 세로 분할이면 높이).
        let minimum: CGFloat
        /// 처음 크기. nil인 칸이 남는 자리를 받고, 창 크기가 바뀔 때도 그 칸이 늘고 준다.
        let initial: CGFloat?
        let content: AnyView
        /// 접을 수 있는 칸이면 지금 접혔는지(nil이면 접을 수 없다). 맨 앞이나 맨 뒤 칸만 접을 수 있다.
        /// 분할선을 끝까지 끌면 접히고, `true`에서 `false`로 바꿔 넘기면 다시 편다.
        /// 처음에는 펼친 채로 시작한다(처음 값 `true`는 받지 않으니 모델이 펼친 상태로 시작해야 한다).
        var collapsed: Bool?

        init(minimum: CGFloat, initial: CGFloat?, content: AnyView, collapsed: Bool? = nil) {
            self.minimum = minimum
            self.initial = initial
            self.content = content
            self.collapsed = collapsed
        }
    }

    enum Axis {
        /// 칸을 옆으로 나란히 둔다.
        case horizontal
        /// 칸을 위아래로 둔다.
        case vertical
    }

    let axis: Axis
    let panes: [Pane]
    /// 사용자가 칸을 접거나 폈다(칸 번호, 접힘).
    var onCollapse: (Int, Bool) -> Void = { _, _ in }

    func makeNSView(context: Context) -> JNSSplitView {
        let split = JNSSplitView()
        split.isVertical = axis == .horizontal
        split.dividerStyle = .thin
        split.configure(panes)
        split.onCollapse = onCollapse
        return split
    }

    func updateNSView(_ split: JNSSplitView, context: Context) {
        split.onCollapse = onCollapse
        split.update(panes)
    }
}

final class JNSSplitView: NSSplitView {
    /// 분할 보기 위임. 분할 보기를 자기 위임으로 두면 메뉴 항목 검사(`respondsToSelector:`)가 끝없이 돌아 앱이 죽는다.
    /// 그래서 따로 둔 객체가 맡고, 분할 보기가 강하게 쥔다(`delegate`는 약한 참조다).
    private let splitDelegate = SplitDelegate()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        splitDelegate.split = self
        delegate = splitDelegate
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        splitDelegate.split = self
        delegate = splitDelegate
    }

    private var hosts: [NSHostingView<AnyView>] = []
    private var initials: [CGFloat?] = []
    private var minimums: [CGFloat] = []
    private var collapsible: [Bool] = []
    /// 접기 전 크기. 다시 펼 때 쓴다.
    private var lastSizes: [CGFloat] = []
    private var reportedCollapsed: [Bool] = []
    /// 모델이 마지막으로 넘긴 접힘 값. 펴기는 이 값이 `true`에서 `false`로 바뀔 때만 한다.
    private var requestedCollapsed: [Bool?] = []
    private var appliedInitialSizes = false
    var onCollapse: (Int, Bool) -> Void = { _, _ in }

    override var dividerColor: NSColor { Theme.NS.line }
    override var dividerThickness: CGFloat { 1 }

    func configure(_ panes: [JSplitView.Pane]) {
        initials = panes.map(\.initial)
        minimums = panes.map(\.minimum)
        collapsible = panes.map { $0.collapsed != nil }
        lastSizes = panes.map { $0.initial ?? $0.minimum }
        reportedCollapsed = panes.map { _ in false }
        requestedCollapsed = panes.map(\.collapsed)
        assert(!panes.contains { $0.collapsed == true }, "JSplitView는 펼친 칸으로 시작한다")
        for (index, pane) in panes.enumerated() {
            let host = NSHostingView(rootView: pane.content)
            // 칸 크기는 분할 뷰가 정한다. SwiftUI 내용이 창 크기를 밀어 올리지 않게 한다.
            host.sizingOptions = []
            host.translatesAutoresizingMaskIntoConstraints = false
            addArrangedSubview(host)
            // 접을 수 있는 칸의 최소 크기는 제약 대신 분할선 위치 제한으로 지킨다(제약이 있으면 접히지 않는다).
            if pane.collapsed == nil {
                let dimension = isVertical ? host.widthAnchor : host.heightAnchor
                dimension.constraint(greaterThanOrEqualToConstant: pane.minimum).isActive = true
            }
            // 처음 크기가 있는 칸은 창 크기가 바뀌어도 그대로 두고, 남는 자리 칸이 늘고 준다.
            setHoldingPriority(pane.initial == nil ? .init(250) : .init(260), forSubviewAt: index)
            hosts.append(host)
        }
    }

    func update(_ panes: [JSplitView.Pane]) {
        for (index, (host, pane)) in zip(hosts, panes).enumerated() {
            host.rootView = pane.content
            // 접힌 칸을 펴라는 요청: 모델이 접힘에서 펼침으로 바뀐 때만 편다.
            // 사용자가 끌어 접은 뒤 그 알림(`onCollapse`)이 모델에 닿기 전의 갱신은 아직 `false`이니, 그때는 펴지 않는다.
            let previous = requestedCollapsed[index]
            requestedCollapsed[index] = pane.collapsed
            if previous == true, pane.collapsed == false, isSubviewCollapsed(host) { expand(index) }
        }
    }

    private func size(_ view: NSView) -> CGFloat { isVertical ? view.frame.width : view.frame.height }
    private var total: CGFloat { isVertical ? bounds.width : bounds.height }

    private func expand(_ index: Int) {
        let size = max(lastSizes[index], minimums[index])
        if index == hosts.count - 1 {
            setPosition(total - size - dividerThickness, ofDividerAt: index - 1)
        } else if index == 0 {
            setPosition(size, ofDividerAt: 0)
        }
    }

    override func layout() {
        super.layout()
        applyInitialSizesOnce()
    }

    /// 처음 자리를 잡을 때 한 번만 칸 크기를 시안 값으로 맞춘다. 남는 자리 칸 앞은 앞에서부터, 뒤는 끝에서부터 잰다.
    private func applyInitialSizesOnce() {
        guard !appliedInitialSizes, hosts.count > 1 else { return }
        let fixed = initials.compactMap { $0 }.reduce(0, +) + dividerThickness * CGFloat(hosts.count - 1)
        guard total > fixed else { return }
        appliedInitialSizes = true
        let flexible = initials.firstIndex { $0 == nil } ?? hosts.count - 1
        var position: CGFloat = 0
        for index in 0..<flexible {
            position += initials[index] ?? 0
            setPosition(position, ofDividerAt: index)
            position += dividerThickness
        }
        var end = total
        for index in stride(from: hosts.count - 1, to: flexible, by: -1) {
            end -= initials[index] ?? 0
            setPosition(end - dividerThickness, ofDividerAt: index - 1)
            end -= dividerThickness
        }
    }

    // MARK: 위임이 부르는 동작

    /// 1px 분할선은 잡기 어려우니 양쪽 3px씩 넓혀 잡게 한다.
    fileprivate func dividerHitRect(forDrawnRect drawnRect: NSRect) -> NSRect {
        isVertical ? drawnRect.insetBy(dx: -3, dy: 0) : drawnRect.insetBy(dx: 0, dy: -3)
    }

    fileprivate func canCollapse(_ subview: NSView) -> Bool {
        guard let index = hosts.firstIndex(where: { $0 === subview }) else { return false }
        return collapsible[index] && (index == 0 || index == hosts.count - 1)
    }

    /// 앞 칸이 접을 수 있는 칸이면 그 최소 크기를 지킨다.
    fileprivate func constrainMin(_ proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard collapsible[dividerIndex] else { return proposedMinimumPosition }
        let start = isVertical ? hosts[dividerIndex].frame.minX : hosts[dividerIndex].frame.minY
        return max(proposedMinimumPosition, start + minimums[dividerIndex])
    }

    /// 뒤 칸이 접을 수 있는 칸이면 그 최소 크기를 지킨다.
    fileprivate func constrainMax(_ proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let next = dividerIndex + 1
        guard collapsible[next] else { return proposedMaximumPosition }
        let end = next == hosts.count - 1 ? total
            : (isVertical ? hosts[next].frame.maxX : hosts[next].frame.maxY)
        return min(proposedMaximumPosition, end - minimums[next] - dividerThickness)
    }

    fileprivate func subviewsDidResize() {
        for (index, host) in hosts.enumerated() where collapsible[index] {
            let collapsed = isSubviewCollapsed(host)
            if !collapsed, size(host) >= minimums[index] { lastSizes[index] = size(host) }
            if collapsed != reportedCollapsed[index] {
                reportedCollapsed[index] = collapsed
                // 레이아웃 도중에 SwiftUI 상태를 바꾸지 않게 다음 차례에 알린다.
                DispatchQueue.main.async { [onCollapse] in onCollapse(index, collapsed) }
            }
        }
    }
}

/// `JNSSplitView`의 위임. 분할 보기의 동작으로 넘긴다.
@MainActor
private final class SplitDelegate: NSObject, NSSplitViewDelegate {
    weak var split: JNSSplitView?

    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                   forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        split?.dividerHitRect(forDrawnRect: drawnRect) ?? proposedEffectiveRect
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        split?.canCollapse(subview) ?? false
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        split?.constrainMin(proposedMinimumPosition, ofSubviewAt: dividerIndex) ?? proposedMinimumPosition
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        split?.constrainMax(proposedMaximumPosition, ofSubviewAt: dividerIndex) ?? proposedMaximumPosition
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        split?.subviewsDidResize()
    }
}
