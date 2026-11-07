import JamakCore
import JamakLLM
import SwiftUI

/// 설정 "LLM" 탭: 프로바이더 카드, 역할별 모델, 동시 요청 수, 연결 확인.
struct LLMSettingsView: View {
    @State private var settings = LLMEnvironment.settings
    @State private var checkMessage: String?
    @State private var isChecking = false
    /// 프로바이더별로 불러온 모델 이름. 이 창에서 목록을 받은 프로바이더가 "연결됨"이다.
    @State private var fetched: [UUID: [String]] = [:]
    /// 키체인에 키가 있는 프로바이더(나타날 때 한 번 읽는다).
    @State private var keyedIDs: Set<UUID> = []
    @State private var editingID: UUID?
    /// 프로바이더의 주소나 키가 바뀌면 올려서, 모델 줄의 오래된 오류 문구를 지운다.
    @State private var revision = 0

    var body: some View {
        SettingsPage {
            SettingsGroup("프로바이더") {
                ForEach(settings.providers) { provider in
                    ProviderCard(
                        provider: provider,
                        hasKey: keyedIDs.contains(provider.id),
                        modelCount: fetched[provider.id]?.count
                    ) { editingID = provider.id }
                }
                if settings.providers.isEmpty {
                    Text("프로바이더가 없어요. 아래에서 추가하세요.")
                        .settingsHint()
                        .padding(.vertical, 12)
                        .padding(.horizontal, 10)
                }
            }
            HStack(spacing: 6) {
                JMenuButton(items: {
                    LLMProvider.Preset.allCases.map { preset in
                        (LLMProvider.make(preset).name, {
                            let provider = LLMProvider.make(preset)
                            settings.providers.append(provider)
                            editingID = provider.id
                        })
                    }
                }) {
                    Label("프로바이더 추가", systemImage: "plus")
                }
                .accessibilityLabel("프로바이더 추가")
                Button("연결 확인") { Task { await check() } }
                    .buttonStyle(.jGhost)
                    .disabled(isChecking || !settings.isTextReady)
                if isChecking { ProgressView().controlSize(.small) }
                if let checkMessage {
                    Text(checkMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text2)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            }
            .padding(.top, -10)

            SettingsGroup("역할별 모델") {
                ModelRow(title: "텍스트 모델", choice: $settings.textModel, settings: settings, fetched: $fetched, optional: false)
                    .id("text\(revision)")
                ModelRow(title: "비전 모델", choice: $settings.visionModel, settings: settings, fetched: $fetched, optional: true)
                    .id("vision\(revision)")
                SettingsRow("동시 요청") {
                    ConcurrencyStepper(value: $settings.concurrency)
                }
            }
            Text("텍스트 모델은 분석·번역·검토에 써요. 비전 모델은 지금은 쓰지 않아요(화면 확인은 나중에 더해요). 32GB 맥이라면 번역에는 Qwen 계열 14B~30B급 모델이 알맞아요.")
                .settingsHint()
                .padding(.top, -10)
        }
        .onAppear(perform: loadKeyFlags)
        .onChange(of: settings) { _, new in LLMEnvironment.settings = new }
        .sheet(isPresented: Binding(get: { editingID != nil }, set: { if !$0 { editingID = nil } })) {
            if let id = editingID, let index = settings.providers.firstIndex(where: { $0.id == id }) {
                ProviderEditor(
                    provider: $settings.providers[index],
                    onChange: { invalidate(id) },
                    onDelete: {
                        try LLMEnvironment.removeProvider(id, from: &settings)
                        fetched[id] = nil
                        editingID = nil
                    },
                    onClose: { editingID = nil }
                )
            }
        }
        .onChange(of: editingID) { _, new in if new == nil { loadKeyFlags() } }
    }

    private func loadKeyFlags() {
        keyedIDs = Set(settings.providers.map(\.id).filter { !(KeychainStore.key(for: $0) ?? "").isEmpty })
    }

    /// 주소나 키가 바뀐 프로바이더의 불러온 목록과 연결 상태, 오래된 메시지를 비운다.
    private func invalidate(_ id: UUID) {
        fetched[id] = nil
        checkMessage = nil
        revision += 1
    }

    /// 텍스트 모델 프로바이더에 `models()`를 불러 한 줄로 보이고, 그 프로바이더 카드의 연결 상태를 갱신한다.
    private func check() async {
        guard let choice = settings.textModel, let provider = settings.provider(id: choice.providerID) else { return }
        isChecking = true
        defer { isChecking = false }
        guard let client = LLMEnvironment.makeClient(provider) else {
            fetched[provider.id] = nil
            checkMessage = "연결할 수 없어요: base URL이 올바르지 않아요"
            return
        }
        do {
            let names = try await client.models()
            fetched[provider.id] = names
            checkMessage = "연결됐어요. 모델 \(names.count)개"
        } catch {
            fetched[provider.id] = nil
            checkMessage = "연결할 수 없어요: \(LLMEnvironment.describe(error))"
        }
    }
}

/// 시안 .prov: 배지 2자, 이름과 주소, 연결 상태, [편집].
private struct ProviderCard: View {
    let provider: LLMProvider
    let hasKey: Bool
    let modelCount: Int?
    let onEdit: () -> Void

    private var badge: String {
        let name = provider.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "?" : String(name.prefix(2)).uppercased()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(badge)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.text2)
                .frame(width: 28, height: 28)
                .background(Theme.bg3, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                Text(provider.baseURL + (hasKey ? " · API 키 저장됨" : ""))
                    .font(.system(size: 11)).foregroundStyle(Theme.text3)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let modelCount {
                HStack(spacing: 6) {
                    Circle().fill(Theme.fixed).frame(width: 7, height: 7)
                        .background(Circle().fill(Theme.fixed.opacity(0.18)).frame(width: 13, height: 13))
                    Text("연결됨 · 모델 \(modelCount)개").monospacedDigit()
                }
                .font(.system(size: 11)).foregroundStyle(Theme.fixedText)
                .accessibilityElement(children: .combine)
            } else {
                Text("확인 안 함").font(.system(size: 11)).foregroundStyle(Theme.text3)
            }
            Button("편집", action: onEdit)
                .buttonStyle(.jSecondary)
                .accessibilityLabel("\(provider.name) 편집")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

/// 어두운 입력란(시안 .input).
private struct JFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(Theme.bg1, in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line2, lineWidth: 1) }
    }
}

private extension View {
    func jField() -> some View { modifier(JFieldStyle()) }
}

/// 시안 .stepper: − 값 +.
private struct ConcurrencyStepper: View {
    @Binding var value: Int

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus", label: "동시 요청 수 줄이기", enabled: value > LLMSettings.concurrencyRange.lowerBound) { value -= 1 }
            Text("\(value)")
                .monospacedDigit()
                .frame(width: 34)
                .accessibilityLabel("동시 요청 수")
                .accessibilityValue("\(value)")
            stepButton("plus", label: "동시 요청 수 늘리기", enabled: value < LLMSettings.concurrencyRange.upperBound) { value += 1 }
        }
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line2, lineWidth: 1) }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .fixedSize()
    }

    private func stepButton(_ icon: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.text2)
                .frame(width: 26, height: 26)
                .background(Theme.bg1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(label)
    }
}

/// 프로바이더 편집 시트: 이름, base URL, API 키, 삭제.
private struct ProviderEditor: View {
    @Binding var provider: LLMProvider
    /// 주소나 키가 바뀌었다(불러온 목록과 연결 상태가 오래됐다).
    let onChange: () -> Void
    let onDelete: () throws -> Void
    let onClose: () -> Void
    @State private var apiKey = ""
    /// 키체인에 들어 있는 값. 나타날 때 읽은 값과 같으면 다시 쓰지 않는다.
    @State private var savedKey = ""
    @State private var keyError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("프로바이더 편집").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
            VStack(alignment: .leading, spacing: 10) {
                field("이름") { TextField("이름", text: $provider.name).jField() }
                field("base URL") {
                    TextField("base URL", text: $provider.baseURL, prompt: Text("https://…/v1"))
                        .autocorrectionDisabled()
                        .jField()
                        .onChange(of: provider.baseURL) { _, _ in onChange() }
                }
                field("API 키") {
                    SecureField("API 키", text: $apiKey, prompt: Text("필요한 서버만"))
                        .jField()
                        .onChange(of: apiKey) { _, new in saveKey(new) }
                }
            }
            if let keyError { Text(keyError).font(.system(size: 11)).foregroundStyle(Theme.suspectText) }
            HStack {
                Button("삭제", role: .destructive) {
                    do { try onDelete() } catch { keyError = error.localizedDescription }
                }
                .buttonStyle(.jSecondary)
                Spacer()
                Button("완료", action: onClose)
                    .buttonStyle(.jPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(Theme.bg1)
        .onAppear {
            let stored = KeychainStore.key(for: provider.id) ?? ""
            savedKey = stored
            apiKey = stored
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.text3)
            content()
        }
    }

    private func saveKey(_ new: String) {
        guard new != savedKey else { return }
        do {
            try KeychainStore.setKey(new, for: provider.id)
            savedKey = new
            keyError = nil
            onChange()
        } catch {
            keyError = error.localizedDescription
        }
    }
}

/// 모델 선택 한 줄: 프로바이더, 모델 이름(직접 입력 + 불러온 목록 메뉴).
private struct ModelRow: View {
    let title: String
    @Binding var choice: ModelChoice?
    let settings: LLMSettings
    @Binding var fetched: [UUID: [String]]
    let optional: Bool
    @State private var fetchError: String?

    private var providerName: String {
        choice.flatMap { settings.provider(id: $0.providerID)?.name } ?? (optional ? "사용 안 함" : "선택 안 됨")
    }

    /// 다른 프로바이더로 바꾸면 모델 이름은 비운다(그 프로바이더에 없는 이름일 수 있다).
    private func select(_ id: UUID?) {
        guard id != choice?.providerID else { return }
        choice = id.map { ModelChoice(providerID: $0, model: "") }
        fetchError = nil
    }

    var body: some View {
        SettingsRow(title) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    JMenuButton(items: {
                        [(optional ? "사용 안 함" : "선택 안 됨", { select(nil) })]
                            + settings.providers.map { provider in (provider.name, { select(provider.id) }) }
                    }) {
                        Text(providerName)
                    }
                    .accessibilityLabel("\(title) 프로바이더")
                    .accessibilityValue(providerName)
                    if let providerID = choice?.providerID {
                        TextField("모델 이름", text: Binding(
                            get: { choice?.model ?? "" },
                            set: { choice = ModelChoice(providerID: providerID, model: $0) }
                        ))
                        .jField()
                        .accessibilityLabel("\(title) 이름")
                    }
                }
                if let providerID = choice?.providerID {
                    HStack(spacing: 6) {
                        let names = fetched[providerID] ?? []
                        JMenuButton(items: {
                            names.map { name in (name, { choice = ModelChoice(providerID: providerID, model: name) }) }
                        }) {
                            Text("목록")
                        }
                        .accessibilityLabel("\(title) 모델 목록")
                        .disabled(names.isEmpty)
                        Button("목록 불러오기") { Task { await load(providerID) } }
                            .buttonStyle(.jGhost)
                        if let fetchError {
                            Text(fetchError).font(.system(size: 11)).foregroundStyle(Theme.text3).lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    private func load(_ providerID: UUID) async {
        guard let provider = settings.provider(id: providerID), let client = LLMEnvironment.makeClient(provider) else {
            fetchError = "base URL이 올바르지 않아요"
            return
        }
        do {
            fetched[providerID] = try await client.models()
            fetchError = nil
        } catch {
            fetchError = "목록을 불러오지 못했어요: \(LLMEnvironment.describe(error))"
        }
    }
}
