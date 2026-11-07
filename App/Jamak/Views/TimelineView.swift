import JamakCore
import SwiftUI

/// `TimelineNSView`를 SwiftUI에 놓는다. 데이터는 모델에서 넘기고, 의도는 모델 메서드로 보낸다.
/// 레인 위치는 `lanes`에 알려 트랙 머리가 줄을 맞추게 한다.
struct TimelineView: NSViewRepresentable {
    @Environment(AppModel.self) private var model
    let lanes: TimelineLaneStore

    func makeNSView(context: Context) -> TimelineContainerView {
        TimelineContainerView(frame: .zero)
    }

    /// 타임라인 칸을 꽉 채운다. 줄이 칸보다 적으면 아래는 타임라인 바탕으로 비워 두고, 많으면 안에서 세로로 스크롤한다.
    /// 그래서 가로 스크롤 막대는 늘 칸 맨 아래에 있다.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TimelineContainerView, context: Context) -> CGSize? {
        let height = proposal.height.map { max($0, 0) } ?? nsView.intrinsicContentSize.height
        return CGSize(width: proposal.width ?? 400, height: height)
    }

    func updateNSView(_ container: TimelineContainerView, context: Context) {
        let model = model
        let lanes = lanes
        let timeline = container.timeline
        var updating = true
        defer { updating = false }
        // SwiftUI가 이 뷰를 고치는 중에 바뀐 값은 다음 차례에 넣는다(갱신 도중 다른 뷰의 상태를 바꾸지 않게).
        // 스크롤처럼 그 밖에서 바뀐 값은 바로 넣어 머리가 레인과 함께 움직이게 한다.
        container.onLanesChange = { metrics in
            if updating {
                DispatchQueue.main.async { lanes.metrics = metrics }
            } else {
                lanes.metrics = metrics
            }
        }
        timeline.onSelect = { model.select($0) }
        timeline.onSeek = { model.seek(ms: $0) }
        timeline.onSelectRange = { model.selectedRange = $0 }
        timeline.onCommit = { clip, actionName in model.commitTiming(clip, actionName: actionName) }
        timeline.onAddClip = { kind, ms in model.addClip(kind: kind, at: ms) }
        timeline.onSelectMemo = { model.selectMemo($0) }
        timeline.onCommitMemo = { memo, actionName in model.commitMemo(memo, actionName: actionName) }
        timeline.onAddMemo = { model.addMemo(at: $0) }
        timeline.onFixOverlap = { model.fixOverlap($0) }
        timeline.onZoom = { model.pxPerSecond = $0 }
        timeline.isEditable = !model.isActiveSetLocked
        timeline.updateTools(hidden: model.hiddenKinds, memosHidden: model.memosHidden, tool: model.timelineTool,
                             snapEnabled: model.snapEnabled, followsPlayhead: !model.timelinePinned)

        timeline.update(set: model.currentView,
                        memos: model.currentSet?.memos ?? [],
                        durationMs: model.durationMs,
                        selectedID: model.selectedCueID,
                        selectedMemoID: model.selectedMemoID,
                        selectedRange: model.selectedRange,
                        playheadMs: model.playheadMs,
                        isPlaying: model.isPlaying,
                        pxPerSecond: model.pxPerSecond)
        timeline.updateBadges(flagged: model.flaggedClipIDs, fixed: model.fixedClipIDs)
        timeline.updateFallback(model.fallbackClipIDs)
        timeline.updateNotes((model.currentSet?.cues ?? []).reduce(into: [:]) { out, cue in
            if cue.hasNote { out[cue.id] = cue.note }
        })
    }
}
