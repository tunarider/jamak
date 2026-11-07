import Foundation
import JamakCore
import JamakLLM
import Observation
import os

/// LLM 역할. 상태 표시줄의 "텍스트", "비전"이다.
enum LLMRoleKind: Sendable { case text, vision }

/// LLM 요청 계측기: 역할별 진행 중 요청 수, 지금 돌리는 작업, 현재 프로젝트의 작업별 토큰 사용량.
/// 앱에 하나(`AppModel.meter`)이고, 파이프라인은 `MeteredChat`을 거쳐 요청한다.
@MainActor @Observable
final class LLMMeter {
    /// 진행 중 요청 수와 그중 출력 중인 수.
    struct RoleActivity: Equatable { var active = 0; var receiving = 0 }

    private(set) var text = RoleActivity()
    private(set) var vision = RoleActivity()
    /// 지금 단계가 쓰는 작업. 단계가 없거나 LLM 단계가 아니면 nil.
    private(set) var runningTask: LLMTask?
    /// 현재 프로젝트의 사용량.
    var usage = TokenUsageBook()

    /// 요청 하나의 영수증. 끝낼 때 돌려준다.
    struct Ticket: Sendable {
        fileprivate let role: LLMRoleKind
        fileprivate let token: ActivityCounter.Token
        fileprivate let book: Int
    }

    @ObservationIgnored private var counters: [LLMRoleKind: ActivityCounter] = [:]
    /// 사용량 장부를 바꿀 때마다 늘린다. 앞 프로젝트에서 시작한 요청의 사용량이 새 프로젝트에 섞이지 않게 한다.
    @ObservationIgnored private var bookGeneration = 0

    /// 프로젝트를 열 때(닫을 때는 nil).
    func load(_ book: TokenUsageBook?) {
        usage = book ?? TokenUsageBook()
        bookGeneration += 1
    }

    /// 기록 지우기. 같은 프로젝트의 장부를 비우는 것이라 `bookGeneration`은 늘리지 않는다:
    /// 지우는 동안 진행 중이던 요청의 사용량은 이 프로젝트에서 실제로 쓴 것이니 비운 장부에 더해지는 게 맞다.
    /// (`bookGeneration`은 다른 프로젝트로 바뀔 때만 늘려, 앞 프로젝트의 사용량이 섞이지 않게 막는다.)
    func reset() {
        usage = TokenUsageBook()
    }

    func setRunningTask(_ task: LLMTask?) {
        guard runningTask != task else { return }
        runningTask = task
    }

    // MARK: 요청 단위(MeteredChat이 부른다)

    func begin(_ role: LLMRoleKind) -> Ticket {
        var counter = counters[role] ?? ActivityCounter()
        let token = counter.begin()
        update(role, counter)
        return Ticket(role: role, token: token, book: bookGeneration)
    }

    /// 출력을 받기 시작했다. 이미 끝난 요청이면 무시된다.
    func receiving(_ ticket: Ticket) {
        guard var counter = counters[ticket.role] else { return }
        counter.receiving(ticket.token)
        update(ticket.role, counter)
    }

    /// 요청이 끝났다(성공·실패·취소). 응답이 온 시도들의 사용량을 그 작업에 더한다.
    func end(_ ticket: Ticket, task: LLMTask, model: String, usages: [ChatUsage?]) {
        if var counter = counters[ticket.role] {
            counter.end(ticket.token)
            update(ticket.role, counter)
        }
        guard ticket.book == bookGeneration, !usages.isEmpty else { return }
        var book = usage
        for u in usages { book.record(task, model: model, usage: u) }
        usage = book
    }

    private func update(_ role: LLMRoleKind, _ counter: ActivityCounter) {
        counters[role] = counter
        let activity = RoleActivity(active: counter.active, receiving: counter.receivingCount)
        switch role {
        case .text: if text != activity { text = activity }
        case .vision: if vision != activity { vision = activity }
        }
    }
}

/// `OpenAIChatClient`를 감싸 작업 키와 역할로 계측한다. 파이프라인은 이걸 그냥 `ChatCompleting`으로 쓴다.
///
/// 한 번의 `complete`는 거절 필드 재시도로 HTTP 요청을 여러 번 보낼 수 있다. 진행 중 상태는 `complete` 하나에 하나로 세고
/// (어느 시도든 출력을 받기 시작하면 출력 중), 사용량은 응답이 온 시도마다 더한다.
/// 끝은 성공·실패·취소 모두 메인 액터에서 기다려 반영하므로 진행 중 상태가 남지 않는다.
struct MeteredChat: ChatCompleting {
    let inner: OpenAIChatClient
    let model: String
    let task: LLMTask
    let role: LLMRoleKind
    let meter: LLMMeter

    /// 같은 클라이언트(거절된 필드 기억을 함께 쓴다)를 다른 작업으로 계측한다.
    func task(_ other: LLMTask) -> MeteredChat {
        MeteredChat(inner: inner, model: model, task: other, role: role, meter: meter)
    }

    func complete(_ request: ChatRequest) async throws -> String {
        let meter = meter
        let ticket = await meter.begin(role)
        let usages = UsageList()
        let observer = ChatObserver(
            phase: { phase in
                guard phase == .receiving else { return }
                // 끝난 뒤 늦게 도착해도 토큰으로 걸러진다.
                Task { @MainActor in meter.receiving(ticket) }
            },
            finished: { usages.append($0) })
        do {
            let reply = try await inner.complete(request, observer: observer)
            await meter.end(ticket, task: task, model: model, usages: usages.all)
            return reply
        } catch {
            await meter.end(ticket, task: task, model: model, usages: usages.all)
            throw error
        }
    }
}

/// 관찰자 콜백(메인 액터 밖)에서 모으는 사용량.
private final class UsageList: Sendable {
    private let items = OSAllocatedUnfairLock<[ChatUsage?]>(initialState: [])
    func append(_ usage: ChatUsage?) { items.withLock { $0.append(usage) } }
    var all: [ChatUsage?] { items.withLock { $0 } }
}
