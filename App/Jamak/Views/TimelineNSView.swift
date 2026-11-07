import AppKit
import JamakCore

/// 타임라인 색. 값은 `Theme` 토큰에서 온다.
enum TimelinePalette {
    static let speech = Theme.NS.speech
    static let sound = Theme.NS.sound
    static let screen = Theme.NS.screen
    static let suspect = Theme.NS.suspect
    /// LLM이 자동으로 고친 조각의 배지.
    static let fixed = Theme.NS.fixed
    /// 겹침(의심 아님) 빗금: 강조색과 구분되는 절제된 호박색.
    static let overlap = Theme.NS.overlap
    /// 강조색: 재생 헤드, 선택 조각 테두리, 선택 구간에만 쓴다.
    static let accent = Theme.NS.accent

    static let background = Theme.NS.bg0
    static let panel = Theme.NS.bg1
    static let line = Theme.NS.line
    static let line2 = Theme.NS.line2
    static let text = Theme.NS.text
    static let dim = Theme.NS.text2
    static let faint = Theme.NS.text3
    static let clipBase = Theme.NS.bg1
    static let grid = NSColor(white: 1, alpha: 0.025)
    /// 숨긴 레인을 덮는 어두운 막.
    static let hiddenLane = NSColor(white: 0, alpha: 0.28)

    static func color(_ kind: SubtitleKind) -> NSColor {
        switch kind {
        case .speech: speech
        case .sound: sound
        case .screen: screen
        }
    }

    /// 조각 바탕: 종류 색 28% + #1b1e22.
    static let fill: [SubtitleKind: NSColor] = Dictionary(uniqueKeysWithValues: SubtitleKind.allCases.map {
        ($0, color($0).blended(withFraction: 0.72, of: clipBase) ?? clipBase)
    })

    static func tint(_ kind: SubtitleKind) -> NSColor? {
        switch kind {
        case .screen: screen.withAlphaComponent(0.035)
        case .sound: sound.withAlphaComponent(0.03)
        case .speech: nil
        }
    }

    static func laneName(_ kind: SubtitleKind) -> String {
        switch kind {
        case .screen: "화면"
        case .speech: "음성"
        case .sound: "소리"
        }
    }

    // MARK: 장면 메모

    static let memo = Theme.NS.memo
    /// 메모 바탕: 메모 색 22% + 조각 바탕(조각보다 조금 옅게).
    static let memoFill = memo.blended(withFraction: 0.78, of: clipBase) ?? clipBase
    static let memoTint = memo.withAlphaComponent(0.03)

    static func laneName(_ lane: TimelineLane) -> String {
        switch lane {
        case .kind(let kind): laneName(kind)
        case .memo: "메모"
        }
    }
}

/// 타임라인 문서 뷰. 눈금자와 네 레인(화면 / 음성 / 소리 / 메모)을 그리고,
/// 마우스 의도(선택, 이동, 드래그 커밋, 조각·메모 추가, 겹침 수정, 줌)를 클로저로 알린다.
/// 편집 자체는 하지 않는다. 숨긴 레인은 자리만 남기고 조각(메모)을 그리지도, 누를 수도 없게 한다.
final class TimelineNSView: NSView {
    // MARK: 의도

    var onSelect: (UUID?) -> Void = { _ in }
    var onSeek: (Int) -> Void = { _ in }
    /// 눈금자를 끌어 구간을 골랐다(nil: 선택 해제).
    var onSelectRange: (ClosedRange<Int>?) -> Void = { _ in }
    var onCommit: (SubtitleClip, String) -> Void = { _, _ in }
    var onAddClip: (SubtitleKind, Int) -> Void = { _, _ in }
    /// 메모를 골랐다(nil은 오지 않는다. 선택 해제는 `onSelect(nil)`이 메모 선택도 푼다).
    var onSelectMemo: (UUID) -> Void = { _ in }
    var onCommitMemo: (SceneMemo, String) -> Void = { _, _ in }
    /// 빈 메모 레인을 더블클릭했다.
    var onAddMemo: (Int) -> Void = { _ in }
    var onFixOverlap: (Overlap) -> Void = { _ in }
    var onZoom: (Double) -> Void = { _ in }
    /// 가로 스크롤·줌·레인 높이가 바뀌었다(트랙 머리를 다시 놓는다).
    var onViewportChange: () -> Void = {}
    /// false면 선택과 이동(재생 위치)만 하고, 끌기·추가·겹침 수정은 하지 않는다(잠긴 자막셋).
    var isEditable = true {
        didSet { if oldValue && !isEditable { clearPreview(); clearMemoPreview(); setRangeDraft(nil); gesture = nil } }
    }

    // MARK: 상태(자막셋이 바뀔 때만 다시 계산한다)

    private(set) var geometry = TimelineGeometry(pxPerSecond: 60)
    private var set = SubtitleSet(language: "")
    private var sortedClips: [SubtitleClip] = []
    private var clipByID: [UUID: SubtitleClip] = [:]
    private var layout = LaneLayout(clips: [])
    private var overlaps: [Overlap] = []
    private var suspectClipIDs: Set<UUID> = []
    /// 검토 티켓 배지: 의심(빨간 "!")과 고침(초록 "✓"). 장부의 id 집합을 그대로 받는다.
    private var flaggedIDs: Set<UUID> = []
    private var fixedIDs: Set<UUID> = []
    /// 출력 언어가 비어 작품 원어로 대신 보인 조각(글자를 기울이고 흐리게 그린다).
    private var fallbackIDs: Set<UUID> = []
    /// 주석이 있는 조각 → 주석. 오른쪽 아래 접힌 모서리로 그리고, 마우스를 올리면 주석을 보인다.
    private var notes: [UUID: String] = [:]
    /// 장면 메모(시작 순서). 메모 레인에 그린다.
    private var memos: [SceneMemo] = []
    private var memoByID: [UUID: SceneMemo] = [:]
    private var memosHidden = false
    private var selectedMemoID: UUID?
    private(set) var laneFrames: [(lane: TimelineLane, y: Double, height: Double)] = []
    /// 숨긴 레인의 종류. 그리기는 조각마다 이 집합을 한 번 찾아본다.
    private var hiddenKinds: Set<SubtitleKind> = []
    /// 클릭 판정에 쓰는 조각: 숨긴 레인의 조각을 뺀 `sortedClips`. 자막셋이나 숨김이 바뀔 때만 다시 만든다.
    private var hittableClips: [SubtitleClip] = []
    private var tool: TimelineTool = .select
    /// false면 끌 때 늘 ⌥를 누른 것과 같다(스냅 안 함).
    private var snapEnabled = true
    /// 재생 중 재생 위치가 화면 밖으로 나가면 따라 옮긴다(도구 막대 "고정"을 켜면 false).
    private var followsPlayhead = true
    /// 눈금자를 그린 세로 위치(보이는 영역 맨 위). 세로로 스크롤하면 바뀌어 다시 그린다.
    private var drawnRulerTop: CGFloat = 0
    private var contentEndMs = 0

    private var durationMs = 0
    private var selectedID: UUID?
    private var playheadMs = 0
    private var isPlaying = false
    private var selectedRange: ClosedRange<Int>?
    /// 눈금자를 끄는 중에 보여 주는 구간. 놓으면 `onSelectRange`로 알린다.
    private var rangeDraft: ClosedRange<Int>?

    // MARK: 드래그

    private enum Gesture {
        /// 눈금자를 누른 시간. `selecting`이면 구간을 고르는 중이다.
        case ruler(anchorMs: Int, selecting: Bool)
        /// 구간 도구로 레인을 누른 곳. 끌면 구간 선택, 그냥 놓으면 누른 조각(`clipID`) 선택이나 선택 해제다.
        case laneRange(anchorMs: Int, start: NSPoint, target: HitTarget?, selecting: Bool)
        case empty
        case clip(original: SubtitleClip, mode: ClipDrag.Mode, start: NSPoint, dragging: Bool)
        case memo(original: SceneMemo, mode: ClipDrag.Mode, start: NSPoint, dragging: Bool)
    }
    /// 누른 곳에 있던 것(구간 도구로 누르기만 했을 때 고른다).
    private enum HitTarget {
        case clip(UUID)
        case memo(UUID)
    }
    private var gesture: Gesture?
    /// 끌고 있는 조각의 `ClipDrag.apply` 결과. 커밋 후 자막셋이 바뀔 때까지 유지한다.
    private var preview: SubtitleClip?
    /// 끌고 있는 메모. 커밋 후 메모가 바뀔 때까지 유지한다.
    private var memoPreview: SceneMemo?
    private var menuOverlap: Overlap?

    static let trailingPadding: CGFloat = 48
    static let playheadSlop: CGFloat = 8
    /// 이보다 짧게 끌면 구간이 아니라 재생 위치 이동이다.
    static let minRangeMs = 150

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        recompute()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: 입력 반영

    func update(set newSet: SubtitleSet, memos newMemos: [SceneMemo], durationMs: Int, selectedID: UUID?,
                selectedMemoID: UUID?, selectedRange: ClosedRange<Int>?, playheadMs: Int, isPlaying: Bool,
                pxPerSecond: Double) {
        var layoutChanged = false
        if newSet != set || newMemos != memos {
            if newSet != set { preview = nil }
            if newMemos != memos { memoPreview = nil }
            set = newSet
            memos = newMemos
            recompute()
            layoutChanged = true
            needsDisplay = true
        }
        if durationMs != self.durationMs {
            self.durationMs = durationMs
            layoutChanged = true
        }
        if layoutChanged { updateFrameSize() }
        if selectedID != self.selectedID {
            for id in [self.selectedID, selectedID].compactMap({ $0 }) { invalidate(clipID: id) }
            self.selectedID = selectedID
            if let selectedID { scrollToClip(selectedID) }
        }
        if selectedMemoID != self.selectedMemoID {
            for id in [self.selectedMemoID, selectedMemoID].compactMap({ $0 }) { invalidate(memoID: id) }
            self.selectedMemoID = selectedMemoID
            if let selectedMemoID { scrollToMemo(selectedMemoID) }
        }
        if selectedRange != self.selectedRange {
            invalidateRange(self.selectedRange)
            self.selectedRange = selectedRange
            invalidateRange(selectedRange)
        }
        self.isPlaying = isPlaying
        if playheadMs != self.playheadMs { movePlayhead(to: playheadMs) }
        if abs(pxPerSecond - geometry.pxPerSecond) > 1e-9 {
            zoom(to: pxPerSecond, anchorDocX: externalZoomAnchor(), notify: false)
        }
        if layoutChanged { onViewportChange() }
    }

    /// 도구 막대와 트랙 머리의 상태를 반영한다.
    func updateTools(hidden: Set<SubtitleKind>, memosHidden: Bool, tool: TimelineTool, snapEnabled: Bool,
                     followsPlayhead: Bool) {
        self.snapEnabled = snapEnabled
        self.followsPlayhead = followsPlayhead
        if tool != self.tool {
            self.tool = tool
            // 끄는 중에 도구가 바뀌면 그 끌기는 버린다(조각 선택은 그대로).
            clearPreview()
            clearMemoPreview()
            setRangeDraft(nil)
            gesture = nil
        }
        if hidden != hiddenKinds {
            hiddenKinds = hidden
            rebuildHittable()
            needsDisplay = true
        }
        if memosHidden != self.memosHidden {
            self.memosHidden = memosHidden
            needsDisplay = true
        }
    }

    private func rebuildHittable() {
        hittableClips = hiddenKinds.isEmpty ? sortedClips : sortedClips.filter { !hiddenKinds.contains($0.kind) }
    }

    /// 검토 티켓 배지를 바꾼다. 바뀐 조각만 다시 그린다.
    func updateBadges(flagged: Set<UUID>, fixed: Set<UUID>) {
        guard flagged != flaggedIDs || fixed != fixedIDs else { return }
        let changed = flagged.symmetricDifference(flaggedIDs).union(fixed.symmetricDifference(fixedIDs))
        flaggedIDs = flagged
        fixedIDs = fixed
        for id in changed { invalidate(clipID: id) }
    }

    /// 주석이 있는 조각을 바꾼다. 바뀐 조각만 다시 그린다.
    func updateNotes(_ new: [UUID: String]) {
        guard new != notes else { return }
        let changed = Set(new.keys).symmetricDifference(notes.keys)
            .union(new.keys.filter { notes[$0] != nil && notes[$0] != new[$0] })
        notes = new
        for id in changed { invalidate(clipID: id) }
    }

    /// 출력 언어가 비어 작품 원어로 대신 보인 조각을 바꾼다. 바뀐 조각만 다시 그린다.
    func updateFallback(_ ids: Set<UUID>) {
        guard ids != fallbackIDs else { return }
        let changed = ids.symmetricDifference(fallbackIDs)
        fallbackIDs = ids
        for id in changed { invalidate(clipID: id) }
    }

    /// 고른 조각이 보이는 영역 밖에 있으면(다음 의심 조각으로 옮긴 경우 등) 보이게 스크롤한다.
    private func scrollToClip(_ id: UUID) {
        guard let clip = clipByID[id], let r = clipRect(clip), let view = enclosingScrollView?.contentView,
              r.maxX < view.bounds.minX || r.minX > view.bounds.maxX else { return }
        scrollHorizontally(to: r.minX - 40)
    }

    /// 고른 메모가 보이는 영역 밖에 있으면 보이게 스크롤한다.
    private func scrollToMemo(_ id: UUID) {
        guard let memo = memoByID[id], let r = memoRect(memo), let view = enclosingScrollView?.contentView,
              r.maxX < view.bounds.minX || r.minX > view.bounds.maxX else { return }
        scrollHorizontally(to: r.minX - 40)
    }

    private func recompute() {
        sortedClips = set.clips.sorted(by: SubtitleClip.timelineOrder)
        clipByID = Dictionary(set.clips.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        layout = LaneLayout(clips: set.clips, memos: memos)
        memoByID = Dictionary(memos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        overlaps = OverlapAnalyzer.speechOverlaps(set.clips)
        var suspects = Set<UUID>()
        for o in overlaps where o.isSuspect {
            suspects.insert(o.first)
            suspects.insert(o.second)
        }
        suspectClipIDs = suspects
        laneFrames = geometry.laneFrames(layout)
        contentEndMs = max(set.clips.map(\.end).max() ?? 0, memos.map(\.end).max() ?? 0)
        rebuildHittable()
    }

    var contentHeight: CGFloat {
        guard let last = laneFrames.last else { return geometry.rulerHeight }
        return last.y + last.height
    }

    /// 문서 크기: 가로는 영상 길이(조각이 더 길면 그 끝)까지, 세로는 레인 높이. 보이는 영역보다 작지 않다.
    func updateFrameSize() {
        let visible = enclosingScrollView?.contentView.bounds.size ?? bounds.size
        let width = max(geometry.x(ms: max(durationMs, contentEndMs)) + Self.trailingPadding, visible.width)
        let height = max(contentHeight, visible.height)
        let size = NSSize(width: ceil(width), height: ceil(height))
        if frame.size != size { setFrameSize(size) }
    }

    // MARK: 재생 헤드

    private func movePlayhead(to ms: Int) {
        let oldX = geometry.x(ms: playheadMs)
        playheadMs = ms
        let newX = geometry.x(ms: ms)
        invalidatePlayhead(at: oldX)
        invalidatePlayhead(at: newX)
        if isPlaying, followsPlayhead, gesture == nil, let clip = enclosingScrollView?.contentView {
            let visible = clip.bounds
            if newX > visible.maxX - 20 || newX < visible.minX {
                scrollHorizontally(to: newX - 40)
            }
        }
    }

    private func invalidatePlayhead(at x: CGFloat) {
        setNeedsDisplay(NSRect(x: x - Self.playheadSlop, y: 0, width: 2 * Self.playheadSlop, height: bounds.height))
    }

    // MARK: 줌과 스크롤

    private func externalZoomAnchor() -> CGFloat {
        let visible = enclosingScrollView?.contentView.bounds ?? bounds
        let playX = geometry.x(ms: playheadMs)
        return visible.minX <= playX && playX <= visible.maxX ? playX : visible.midX
    }

    /// `anchorDocX`에 있던 시간이 화면에서 같은 자리에 남도록 줌을 바꾼다.
    private func zoom(to px: Double, anchorDocX: CGFloat, notify: Bool) {
        guard let clip = enclosingScrollView?.contentView else {
            geometry.pxPerSecond = px
            return
        }
        let offset = anchorDocX - clip.bounds.minX
        let anchorSeconds = Double(anchorDocX) / geometry.pxPerSecond
        geometry.pxPerSecond = px
        updateFrameSize()
        scrollHorizontally(to: anchorSeconds * geometry.pxPerSecond - offset)
        needsDisplay = true
        onViewportChange()
        if notify { onZoom(geometry.pxPerSecond) }
    }

    private func scrollHorizontally(to x: CGFloat) {
        guard let scrollView = enclosingScrollView else { return }
        let clip = scrollView.contentView
        let maxX = max(0, frame.width - clip.bounds.width)
        clip.scroll(to: NSPoint(x: min(max(0, x), maxX), y: clip.bounds.minY))
        scrollView.reflectScrolledClipView(clip)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
            guard delta != 0 else { return }
            let anchor = convert(event.locationInWindow, from: nil).x
            zoom(to: geometry.pxPerSecond * exp(Double(delta) * 0.01), anchorDocX: anchor, notify: true)
            return
        }
        // 세로로 스크롤할 게 없으면 휠의 세로 움직임을 가로 스크롤로 쓴다.
        if let clip = enclosingScrollView?.contentView, frame.height <= clip.bounds.height + 0.5,
           abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            scrollHorizontally(to: clip.bounds.minX - event.scrollingDeltaY * scale)
            return
        }
        super.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        let anchor = convert(event.locationInWindow, from: nil).x
        zoom(to: geometry.pxPerSecond * (1 + Double(event.magnification)), anchorDocX: anchor, notify: true)
    }

    // MARK: 그리기

    /// 줌에 따라 1/5/10/30/60초 중 눈금 사이가 64pt 이상인 가장 작은 간격.
    var tickIntervalSeconds: Int {
        [1, 5, 10, 30, 60].first { Double($0) * geometry.pxPerSecond >= 64 } ?? 60
    }

    private func clipRect(_ clip: SubtitleClip, row: Int) -> NSRect? {
        guard let lane = laneFrames.first(where: { $0.lane == .kind(clip.kind) }) else { return nil }
        let minX = geometry.x(ms: clip.start)
        let maxX = geometry.x(ms: clip.end)
        let y = lane.y + geometry.lanePadding + Double(row) * geometry.rowHeight + 2
        return NSRect(x: minX, y: y, width: max(1, maxX - minX), height: geometry.rowHeight - 4)
    }

    private func clipRect(_ clip: SubtitleClip) -> NSRect? {
        clipRect(clip, row: layout.rowOf[clip.id] ?? 0)
    }

    /// 미리보기 조각은 같은 레인이면 원래 행, 다른 레인이면 첫 행에 그린다.
    private func previewRect(_ p: SubtitleClip) -> NSRect? {
        let original = clipByID[p.id]
        let row = original?.kind == p.kind ? (layout.rowOf[p.id] ?? 0) : 0
        return clipRect(p, row: row)
    }

    private func invalidate(clipID: UUID) {
        if let clip = clipByID[clipID], let r = clipRect(clip) { setNeedsDisplay(r.insetBy(dx: -4, dy: -4)) }
    }

    /// 메모 막대 자리. 끄는 중인 메모는 원래 행에 그린다.
    private func memoRect(_ memo: SceneMemo) -> NSRect? {
        guard let lane = laneFrames.first(where: { $0.lane == .memo }) else { return nil }
        let row = layout.memoRowOf[memo.id] ?? 0
        let minX = geometry.x(ms: memo.start)
        let maxX = geometry.x(ms: memo.end)
        let y = lane.y + geometry.lanePadding + Double(row) * geometry.rowHeight + 2
        return NSRect(x: minX, y: y, width: max(1, maxX - minX), height: geometry.rowHeight - 4)
    }

    private func invalidate(memoID: UUID) {
        if let memo = memoByID[memoID], let r = memoRect(memo) { setNeedsDisplay(r.insetBy(dx: -4, dy: -4)) }
    }

    private func isHidden(_ lane: TimelineLane) -> Bool {
        switch lane {
        case .kind(let kind): hiddenKinds.contains(kind)
        case .memo: memosHidden
        }
    }

    /// 겹침 빗금 자리: 겹친 구간(가로) × 겹친 두 조각의 행 사이(세로). 누를 수 있는 영역과 같다.
    private func hatchRect(_ o: Overlap) -> NSRect? {
        guard let lane = laneFrames.first(where: { $0.lane == .kind(.speech) }),
              let a = layout.rowOf[o.first], let b = layout.rowOf[o.second] else { return nil }
        let top = lane.y + geometry.lanePadding + Double(min(a, b)) * geometry.rowHeight
        let bottom = lane.y + geometry.lanePadding + Double(max(a, b) + 1) * geometry.rowHeight
        let minX = geometry.x(ms: o.start)
        let maxX = geometry.x(ms: o.end)
        return NSRect(x: minX, y: top, width: max(2, maxX - minX), height: bottom - top)
    }

    override func draw(_ dirtyRect: NSRect) {
        TimelinePalette.background.setFill()
        dirtyRect.fill()

        let minMs = geometry.ms(x: dirtyRect.minX) - 1
        let maxMs = geometry.ms(x: dirtyRect.maxX) + 1

        drawLanes(dirtyRect)
        drawGrid(dirtyRect)

        let dragged = preview?.id
        let hidden = hiddenKinds
        for clip in sortedClips {
            if clip.start > maxMs { break }
            guard clip.end >= minMs, !hidden.contains(clip.kind), let r = clipRect(clip), r.intersects(dirtyRect)
            else { continue }
            drawClip(clip, in: r, faded: clip.id == dragged)
        }

        // 겹침은 음성 조각끼리만이라 음성 레인을 숨기면 빗금도 없다.
        if !hidden.contains(.speech) {
            for o in overlaps where o.end >= minMs && o.start <= maxMs {
                if let r = hatchRect(o), r.intersects(dirtyRect) { drawHatch(r, suspect: o.isSuspect) }
            }
        }

        if let preview, let r = previewRect(preview), r.intersects(dirtyRect) {
            drawClip(preview, in: r, faded: false)
        }

        if !memosHidden {
            let draggedMemo = memoPreview?.id
            // 메모는 몇 개 안 되니 정렬에 기대지 않고 모두 본다.
            for memo in memos {
                guard memo.start <= maxMs, memo.end >= minMs, let r = memoRect(memo), r.intersects(dirtyRect)
                else { continue }
                drawMemo(memo, in: r, faded: memo.id == draggedMemo)
            }
            if let memoPreview, let r = memoRect(memoPreview), r.intersects(dirtyRect) {
                drawMemo(memoPreview, in: r, faded: false)
            }
        }

        let rulerTop = self.rulerTop
        drawnRulerTop = rulerTop
        if dirtyRect.minY < rulerTop + geometry.rulerHeight, dirtyRect.maxY > rulerTop { drawRuler(dirtyRect, top: rulerTop) }
        drawRangeBand(dirtyRect)
        drawPlayhead(dirtyRect)
    }

    /// 고른 구간(끄는 중이면 그 구간)의 강조색 반투명 띠. 타임라인 전체 높이에 그린다.
    private func drawRangeBand(_ dirty: NSRect) {
        guard let range = rangeDraft ?? selectedRange else { return }
        let r = bandRect(range)
        guard r.intersects(dirty) else { return }
        TimelinePalette.accent.withAlphaComponent(0.07).setFill()
        r.fill(using: .sourceOver)
        TimelinePalette.accent.withAlphaComponent(0.7).setFill()
        NSRect(x: r.minX, y: 0, width: 1, height: r.height).fill(using: .sourceOver)
        NSRect(x: r.maxX - 1, y: 0, width: 1, height: r.height).fill(using: .sourceOver)
    }

    private func bandRect(_ range: ClosedRange<Int>) -> NSRect {
        let minX = geometry.x(ms: range.lowerBound)
        let maxX = geometry.x(ms: range.upperBound)
        return NSRect(x: minX, y: 0, width: max(1, maxX - minX), height: bounds.height)
    }

    private func invalidateRange(_ range: ClosedRange<Int>?) {
        guard let range else { return }
        setNeedsDisplay(bandRect(range).insetBy(dx: -2, dy: 0))
    }

    private func setRangeDraft(_ range: ClosedRange<Int>?) {
        guard range != rangeDraft else { return }
        invalidateRange(rangeDraft ?? selectedRange)
        rangeDraft = range
        invalidateRange(range ?? selectedRange)
    }

    /// 눈금자 위치의 시간. 0과 영상 길이(조각이 더 길면 그 끝) 사이로 제한한다.
    private func rulerMs(atX x: CGFloat) -> Int {
        min(max(0, geometry.ms(x: x)), max(durationMs, contentEndMs))
    }

    private func drawLanes(_ dirty: NSRect) {
        for lane in laneFrames {
            let r = NSRect(x: dirty.minX, y: lane.y, width: dirty.width, height: lane.height)
            guard r.intersects(dirty) else { continue }
            let tint: NSColor? = switch lane.lane {
            case .kind(let kind): TimelinePalette.tint(kind)
            case .memo: TimelinePalette.memoTint
            }
            if isHidden(lane.lane) {
                TimelinePalette.hiddenLane.setFill()
                r.fill(using: .sourceOver)
            } else if let tint {
                tint.setFill()
                r.fill(using: .sourceOver)
            }
            TimelinePalette.line.setFill()
            NSRect(x: dirty.minX, y: lane.y + lane.height - 1, width: dirty.width, height: 1).fill()
        }
    }

    private func forEachTick(in dirty: NSRect, _ body: (CGFloat, Int) -> Void) {
        let stepMs = tickIntervalSeconds * 1000
        let first = max(0, geometry.ms(x: dirty.minX - 80) / stepMs * stepMs)
        var ms = first
        while geometry.x(ms: ms) <= dirty.maxX {
            body(geometry.x(ms: ms), ms)
            ms += stepMs
        }
    }

    private func drawGrid(_ dirty: NSRect) {
        TimelinePalette.grid.setFill()
        let top = geometry.rulerHeight
        forEachTick(in: dirty) { x, _ in
            NSRect(x: x, y: top, width: 1, height: bounds.height - top).fill(using: .sourceOver)
        }
    }

    private static let clipTextAttributes: [NSAttributedString.Key: Any] = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: TimelinePalette.text, .paragraphStyle: style]
    }()

    /// 대신 보인 작품 원어 글자: 기울임에 흐리게(시안 .clip.fb).
    private static let fallbackTextAttributes: [NSAttributedString.Key: Any] = {
        var attributes = clipTextAttributes
        attributes[.foregroundColor] = TimelinePalette.text.withAlphaComponent(0.6)
        // 한글·일본어 글꼴에는 기울임 모양이 없으니 글자를 기울여 그린다.
        attributes[.obliqueness] = 0.18
        return attributes
    }()

    private func drawClip(_ clip: SubtitleClip, in r: NSRect, faded: Bool) {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        defer { context.restoreGraphicsState() }
        if faded { context.cgContext.setAlpha(0.35) }

        let color = TimelinePalette.color(clip.kind)
        let radius = min(4, r.width / 2)
        let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        TimelinePalette.fill[clip.kind]?.setFill()
        path.fill()

        context.saveGraphicsState()
        path.addClip()
        color.setFill()
        NSRect(x: r.minX, y: r.minY, width: min(3, r.width), height: r.height).fill()
        context.restoreGraphicsState()

        let border = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        border.lineWidth = 1
        (suspectClipIDs.contains(clip.id) ? TimelinePalette.suspect : color.withAlphaComponent(0.7)).setStroke()
        border.stroke()

        let badge = flaggedIDs.contains(clip.id) ? Badge.suspect : fixedIDs.contains(clip.id) ? Badge.fixed : nil
        if r.width > 18 {
            let text = clip.text.replacingOccurrences(of: "\n", with: " ")
            let lineHeight: CGFloat = 16
            let reserved: CGFloat = badge == nil ? 0 : Self.badgeSize + 2
            let textRect = NSRect(x: r.minX + 10, y: r.midY - lineHeight / 2, width: r.width - 16 - reserved,
                                  height: lineHeight)
            let attributes = fallbackIDs.contains(clip.id) ? Self.fallbackTextAttributes : Self.clipTextAttributes
            (text as NSString).draw(in: textRect, withAttributes: attributes)
        }
        if let badge { drawBadge(badge, in: r) }
        if notes[clip.id] != nil { drawNoteCorner(in: r, radius: radius) }

        if clip.id == selectedID {
            let outline = NSBezierPath(roundedRect: r.insetBy(dx: -1, dy: -1), xRadius: radius + 1, yRadius: radius + 1)
            outline.lineWidth = 2
            TimelinePalette.accent.setStroke()
            outline.stroke()
        }
    }

    /// 메모 막대: 분홍 바탕, 왼쪽 막대, 점선 테두리(조각과 구분). 글이 비었으면 흐린 "빈 메모".
    private func drawMemo(_ memo: SceneMemo, in r: NSRect, faded: Bool) {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        defer { context.restoreGraphicsState() }
        if faded { context.cgContext.setAlpha(0.35) }

        let color = TimelinePalette.memo
        let radius = min(4, r.width / 2)
        let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        TimelinePalette.memoFill.setFill()
        path.fill()

        context.saveGraphicsState()
        path.addClip()
        color.setFill()
        NSRect(x: r.minX, y: r.minY, width: min(3, r.width), height: r.height).fill()
        context.restoreGraphicsState()

        let border = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        border.lineWidth = 1
        border.setLineDash([4, 3], count: 2, phase: 0)
        color.withAlphaComponent(0.75).setStroke()
        border.stroke()

        if r.width > 18 {
            let text = memo.text.replacingOccurrences(of: "\n", with: " ")
            let lineHeight: CGFloat = 16
            let textRect = NSRect(x: r.minX + 10, y: r.midY - lineHeight / 2, width: r.width - 16, height: lineHeight)
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                ("빈 메모" as NSString).draw(in: textRect, withAttributes: Self.emptyMemoAttributes)
            } else {
                (text as NSString).draw(in: textRect, withAttributes: Self.clipTextAttributes)
            }
        }

        if memo.id == selectedMemoID {
            let outline = NSBezierPath(roundedRect: r.insetBy(dx: -1, dy: -1), xRadius: radius + 1, yRadius: radius + 1)
            outline.lineWidth = 2
            TimelinePalette.accent.setStroke()
            outline.stroke()
        }
    }

    private static let emptyMemoAttributes: [NSAttributedString.Key: Any] = {
        var attributes = clipTextAttributes
        attributes[.foregroundColor] = TimelinePalette.faint
        return attributes
    }()

    private enum Badge { case suspect, fixed }

    static let badgeSize: CGFloat = 13

    private static let badgeAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 9.5, weight: .heavy),
        .foregroundColor: NSColor.white,
    ]

    /// 조각 오른쪽 위 안쪽의 작은 원 배지. 의심은 빨간 "!", 고침은 초록 "✓".
    private func drawBadge(_ badge: Badge, in r: NSRect) {
        let size = Self.badgeSize
        let rect = NSRect(x: max(r.minX, r.maxX - size - 2), y: r.minY + 2, width: size, height: size)
        (badge == .suspect ? TimelinePalette.suspect : TimelinePalette.fixed).setFill()
        NSBezierPath(ovalIn: rect).fill()
        let mark = (badge == .suspect ? "!" : "✓") as NSString
        let markSize = mark.size(withAttributes: Self.badgeAttributes)
        mark.draw(at: NSPoint(x: rect.midX - markSize.width / 2, y: rect.midY - markSize.height / 2),
                  withAttributes: Self.badgeAttributes)
    }

    /// 주석 표시: 조각 오른쪽 아래의 접힌 모서리(메모 색).
    private func drawNoteCorner(in r: NSRect, radius: CGFloat) {
        let size = min(8, r.width / 2, r.height / 2)
        guard size >= 3 else { return }
        let corner = NSBezierPath()
        corner.move(to: NSPoint(x: r.maxX, y: r.maxY - size))
        corner.line(to: NSPoint(x: r.maxX, y: r.maxY))
        corner.line(to: NSPoint(x: r.maxX - size, y: r.maxY))
        corner.close()
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).addClip()
        TimelinePalette.memo.setFill()
        corner.fill()
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    private func drawHatch(_ r: NSRect, suspect: Bool) {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        defer { context.restoreGraphicsState() }
        let color = suspect ? TimelinePalette.suspect : TimelinePalette.overlap
        NSBezierPath(rect: r).addClip()
        color.withAlphaComponent(0.12).setFill()
        r.fill(using: .sourceOver)
        let stripes = NSBezierPath()
        var x = r.minX - r.height
        while x < r.maxX {
            stripes.move(to: NSPoint(x: x, y: r.maxY))
            stripes.line(to: NSPoint(x: x + r.height, y: r.minY))
            x += 6
        }
        stripes.lineWidth = 1.5
        color.withAlphaComponent(suspect ? 0.85 : 0.5).setStroke()
        stripes.stroke()
    }

    private static let rulerAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium),
        .foregroundColor: TimelinePalette.dim,
    ]

    /// 눈금자 맨 위: 보이는 영역의 맨 위. 세로로 스크롤해도 눈금자는 늘 위에 붙어 있다(아래 조각을 가린다).
    private var rulerTop: CGFloat { max(0, visibleRect.minY) }

    private func drawRuler(_ dirty: NSRect, top: CGFloat) {
        let h = geometry.rulerHeight
        TimelinePalette.panel.setFill()
        NSRect(x: dirty.minX, y: top, width: dirty.width, height: h).fill()
        TimelinePalette.line.setFill()
        NSRect(x: dirty.minX, y: top + h - 1, width: dirty.width, height: 1).fill()
        forEachTick(in: dirty) { x, ms in
            TimelinePalette.line2.setFill()
            NSRect(x: x, y: top, width: 1, height: h - 1).fill()
            (Timecode.short(ms) as NSString).draw(at: NSPoint(x: x + 4, y: top + 4), withAttributes: Self.rulerAttributes)
        }
    }

    /// 세로 스크롤이 바뀌었다. 눈금자가 옮겨 붙으니 보이는 영역을 다시 그린다(스크롤은 그린 픽셀을 그대로 옮긴다).
    func verticalScrollChanged() {
        guard rulerTop != drawnRulerTop else { return }
        setNeedsDisplay(visibleRect)
    }

    private func drawPlayhead(_ dirty: NSRect) {
        let x = geometry.x(ms: playheadMs)
        guard x >= dirty.minX - Self.playheadSlop, x <= dirty.maxX + Self.playheadSlop else { return }
        TimelinePalette.accent.setFill()
        NSRect(x: x - 0.75, y: 0, width: 1.5, height: bounds.height).fill()
        let top = rulerTop
        let head = NSBezierPath()
        head.move(to: NSPoint(x: x - 6, y: top))
        head.line(to: NSPoint(x: x + 6, y: top))
        head.line(to: NSPoint(x: x, y: top + 8))
        head.close()
        head.fill()
    }

    // MARK: 마우스

    /// 의심 빗금을 누를 수 있는 영역: 빗금 자리와 같고, 가로만 최소 8pt로 넓힌다.
    private func suspectHitRect(_ o: Overlap) -> NSRect? {
        guard o.isSuspect, let r = hatchRect(o) else { return nil }
        let grow = max(0, (8 - r.width) / 2)
        return r.insetBy(dx: -grow, dy: 0)
    }

    private func suspectOverlap(at p: NSPoint) -> Overlap? {
        guard !hiddenKinds.contains(.speech) else { return nil }
        return overlaps.first { suspectHitRect($0)?.contains(p) ?? false }
    }

    /// 숨긴 레인을 뺀 조각 클릭 판정.
    private func hitClip(_ p: NSPoint) -> (UUID, ClipDrag.Mode)? {
        geometry.hit(p, clips: hittableClips, layout: layout)
    }

    /// 숨긴 메모 레인이면 nil인 메모 클릭 판정.
    private func hitMemo(_ p: NSPoint) -> (UUID, ClipDrag.Mode)? {
        guard !memosHidden else { return nil }
        return geometry.hitMemo(p, memos: memos, layout: layout)
    }

    /// 끌 때 스냅할지: 스냅이 켜져 있고 ⌥를 누르지 않았다.
    private func snaps(_ event: NSEvent) -> Bool {
        snapEnabled && !event.modifierFlags.contains(.option)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        clearPreview()
        clearMemoPreview()
        let p = convert(event.locationInWindow, from: nil)

        if p.y < rulerTop + geometry.rulerHeight {
            let ms = rulerMs(atX: p.x)
            gesture = .ruler(anchorMs: ms, selecting: false)
            onSeek(ms)
            return
        }
        // 구간 도구: 레인 위 드래그는 구간 선택이다. 조각을 끌거나 늘이지 않고, 누르기만 하면 그 조각을 고른다.
        if tool == .range {
            let target: HitTarget? = if let id = hitClip(p)?.0 { .clip(id) } else { hitMemo(p).map { .memo($0.0) } }
            gesture = .laneRange(anchorMs: rulerMs(atX: p.x), start: p, target: target, selecting: false)
            return
        }
        // 조각을 누르면 늘 선택·드래그다. 조각이 없는 빗금 자리를 누를 때만 수정 메뉴를 띄운다.
        if let (id, mode) = hitClip(p), let clip = clipByID[id] {
            gesture = .clip(original: clip, mode: mode, start: p, dragging: false)
            return
        }
        if let (id, mode) = hitMemo(p), let memo = memoByID[id] {
            gesture = .memo(original: memo, mode: mode, start: p, dragging: false)
            return
        }
        if isEditable, let overlap = suspectOverlap(at: p) {
            gesture = nil
            showFixMenu(for: overlap, event: event)
            return
        }
        if isEditable, event.clickCount == 2, let lane = geometry.lane(atY: p.y, layout: layout), !isHidden(lane) {
            gesture = nil
            let ms = max(0, geometry.ms(x: p.x))
            switch lane {
            case .kind(let kind): onAddClip(kind, ms)
            case .memo: onAddMemo(ms)
            }
            return
        }
        gesture = .empty
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch gesture {
        case .ruler(let anchor, var selecting):
            autoscroll(with: event)
            let ms = rulerMs(atX: p.x)
            if !selecting {
                // 짧게 끌면 예전처럼 재생 위치만 옮긴다.
                guard abs(ms - anchor) >= Self.minRangeMs else {
                    onSeek(ms)
                    return
                }
                selecting = true
                gesture = .ruler(anchorMs: anchor, selecting: true)
            }
            setRangeDraft(min(anchor, ms)...max(anchor, ms))
        case .laneRange(let anchor, let start, let target, var selecting):
            let ms = rulerMs(atX: p.x)
            if !selecting {
                // 조금 흔들린 클릭은 구간이 아니다(눈금자와 같은 최소 길이에 3pt 이상 움직임).
                guard abs(ms - anchor) >= Self.minRangeMs, abs(p.x - start.x) >= 3 else { return }
                selecting = true
                gesture = .laneRange(anchorMs: anchor, start: start, target: target, selecting: true)
            }
            autoscroll(with: event)
            setRangeDraft(min(anchor, ms)...max(anchor, ms))
        case .clip(let original, let mode, let start, var dragging):
            guard isEditable else { return }
            let dx = p.x - start.x
            let dy = p.y - start.y
            if !dragging {
                guard hypot(dx, dy) >= 3 else { return }
                dragging = true
                gesture = .clip(original: original, mode: mode, start: start, dragging: true)
                // 끄는 조각도 선택한다(누르기만 했을 때와 같게).
                onSelect(original.id)
            }
            autoscroll(with: event)
            // 숨긴 레인으로는 옮기지 않는다(옮기면 보이지 않게 된다).
            // 메모 레인으로도 옮기지 않는다(조각 종류가 아니다).
            let target = mode == .move ? geometry.lane(atY: p.y, layout: layout)?.kind.flatMap {
                hiddenKinds.contains($0) ? nil : $0
            } : nil
            let next = ClipDrag.apply(original, mode: mode, deltaMs: geometry.ms(x: dx), targetLane: target,
                                      durationMs: max(durationMs, original.end), snap: snaps(event))
            for r in [preview.flatMap(previewRect), previewRect(next), clipRect(original)].compactMap({ $0 }) {
                setNeedsDisplay(r.insetBy(dx: -4, dy: -4))
            }
            preview = next
        case .memo(let original, let mode, let start, var dragging):
            guard isEditable else { return }
            let dx = p.x - start.x
            if !dragging {
                guard hypot(dx, p.y - start.y) >= 3 else { return }
                dragging = true
                gesture = .memo(original: original, mode: mode, start: start, dragging: true)
                onSelectMemo(original.id)
            }
            autoscroll(with: event)
            let next = ClipDrag.apply(original, mode: mode, deltaMs: geometry.ms(x: dx),
                                      durationMs: max(durationMs, original.end), snap: snaps(event))
            for r in [memoPreview.flatMap(memoRect), memoRect(next), memoRect(original)].compactMap({ $0 }) {
                setNeedsDisplay(r.insetBy(dx: -4, dy: -4))
            }
            memoPreview = next
        case .empty, nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { gesture = nil }
        switch gesture {
        case .clip(let original, let mode, _, let dragging):
            if dragging {
                if let preview, preview != original {
                    onCommit(preview, mode == .move ? "조각 이동" : "길이 조정")
                } else {
                    clearPreview()
                }
            } else {
                onSelect(original.id)
                onSeek(original.start)
            }
        case .memo(let original, let mode, _, let dragging):
            if dragging {
                if let memoPreview, memoPreview != original {
                    onCommitMemo(memoPreview, mode == .move ? "메모 이동" : "메모 길이 조정")
                } else {
                    clearMemoPreview()
                }
            } else {
                onSelectMemo(original.id)
                onSeek(original.start)
            }
        case .empty:
            onSelect(nil)
            onSelectRange(nil)
        case .ruler(_, let selecting):
            // 다시 짧게 줄였다 놓으면 구간을 바꾸지 않는다.
            if !(selecting && commitRangeDraft()) { setRangeDraft(nil) }
        case .laneRange(_, _, let target, let selecting):
            if selecting {
                if !commitRangeDraft() { setRangeDraft(nil) }
            } else if case .clip(let clipID) = target, let clip = clipByID[clipID] {
                onSelect(clipID)
                onSeek(clip.start)
            } else if case .memo(let memoID) = target, let memo = memoByID[memoID] {
                onSelectMemo(memoID)
                onSeek(memo.start)
            } else {
                onSelect(nil)
                onSelectRange(nil)
            }
        case nil:
            break
        }
    }

    /// 끄는 중인 구간이 최소 길이 이상이면 고른 구간으로 정하고 알린다.
    private func commitRangeDraft() -> Bool {
        guard let draft = rangeDraft, draft.upperBound - draft.lowerBound >= Self.minRangeMs else { return false }
        rangeDraft = nil
        invalidateRange(selectedRange)
        selectedRange = draft
        invalidateRange(draft)
        onSelectRange(draft)
        return true
    }

    private func clearPreview() {
        guard let p = preview else { return }
        preview = nil
        if let r = previewRect(p) { setNeedsDisplay(r.insetBy(dx: -4, dy: -4)) }
        invalidate(clipID: p.id)
    }

    private func clearMemoPreview() {
        guard let p = memoPreview else { return }
        memoPreview = nil
        if let r = memoRect(p) { setNeedsDisplay(r.insetBy(dx: -4, dy: -4)) }
        invalidate(memoID: p.id)
    }

    private func showFixMenu(for overlap: Overlap, event: NSEvent) {
        NSMenu.popUpContextMenu(fixMenu(for: overlap), with: event, for: self)
    }

    private func fixMenu(for overlap: Overlap) -> NSMenu {
        menuOverlap = overlap
        let menu = NSMenu()
        let item = NSMenuItem(title: "앞 조각 끝을 뒤 조각 시작에 맞추기", action: #selector(fixMenuChosen), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    /// 오른쪽 클릭은 조각 위에서도 빗금 수정 메뉴를 띄운다.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard isEditable, let overlap = suspectOverlap(at: convert(event.locationInWindow, from: nil)) else { return nil }
        return fixMenu(for: overlap)
    }

    @objc private func fixMenuChosen() {
        guard let overlap = menuOverlap else { return }
        menuOverlap = nil
        onFixOverlap(overlap)
    }

    // MARK: 커서

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // 구간 도구는 조각 길이를 바꾸지 않으니 늘이기 커서를 보이지 않는다.
        let hit = tool == .select ? (hitClip(p) ?? hitMemo(p)) : nil
        if let mode = hit?.1, mode != .move {
            NSCursor.resizeLeftRight.set()
        } else {
            NSCursor.arrow.set()
        }
        let note = hitClip(p).flatMap { notes[$0.0] }.map { "주석: \($0)" }
        if toolTip != note { toolTip = note }
    }
}

/// 트랙 머리가 레인과 줄을 맞추는 데 쓰는 값: 눈금자 높이, 레인마다 위치·높이(문서 좌표), 세로 스크롤 위치.
struct TimelineLaneMetrics: Equatable {
    struct Lane: Equatable {
        var lane: TimelineLane
        var y: Double
        var height: Double
    }

    var rulerHeight: Double = 30
    var lanes: [Lane] = []
    var offsetY: Double = 0
}

/// 가로·세로로 스크롤되는 타임라인. 트랙 머리(SwiftUI)는 `onLanesChange`로 받은 값으로 줄을 맞춘다.
final class TimelineContainerView: NSView {
    let scrollView = NSScrollView()
    let timeline = TimelineNSView(frame: .zero)
    /// 레인 위치·높이나 세로 스크롤이 바뀌었다. 바뀐 때만 부른다.
    var onLanesChange: (TimelineLaneMetrics) -> Void = { _ in }
    private var metrics = TimelineLaneMetrics()

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        // 문서가 보이는 영역보다 낮으면 위에 붙인다(기본 클립 뷰는 아래에 붙여 눈금자 위에 빈 칸이 생긴다).
        scrollView.contentView = FlippedClipView()
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = TimelinePalette.background
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = timeline
        scrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(scrollView)

        timeline.onViewportChange = { [weak self] in self?.syncLanes() }
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// 높이는 레인 내용에 맞춘다(가로 스크롤 막대 몫 포함). 행이 아주 많으면 세로로 스크롤한다.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: min(max(timeline.contentHeight + 12, 170), 320))
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        // 클립 뷰 크기를 먼저 맞춰야 문서 높이를 새 크기로 잡는다(패널을 늘렸을 때 문서가 예전 높이에 머물지 않게).
        scrollView.tile()
        timeline.updateFrameSize()
        syncLanes()
    }

    @objc private func clipBoundsChanged() {
        timeline.verticalScrollChanged()
        syncLanes()
    }

    private func syncLanes() {
        var next = TimelineLaneMetrics(
            rulerHeight: timeline.geometry.rulerHeight,
            lanes: timeline.laneFrames.map { .init(lane: $0.lane, y: $0.y, height: $0.height) },
            offsetY: Double(scrollView.contentView.bounds.minY))
        if next.lanes.map(\.height) != metrics.lanes.map(\.height) { invalidateIntrinsicContentSize() }
        next.offsetY = max(0, next.offsetY)
        guard next != metrics else { return }
        metrics = next
        onLanesChange(next)
    }
}

/// 위에서부터 쌓는 클립 뷰. 문서가 보이는 영역보다 낮을 때 위에 붙는다.
private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}
