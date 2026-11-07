import JamakCore
import JamakMedia
import SwiftUI

/// 설정: 일반(내 언어) / 받아쓰기(모델, 원문 언어) / LLM / 저장 공간(받은 모델과 프레임 캐시).
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(GenerationController.self) private var generation
    @AppStorage(GenerationController.modelIDKey) private var modelID = Transcriber.defaultModelID
    @AppStorage(GenerationController.sourceLanguageKey) private var sourceLanguage = GenerationController.defaultSourceLanguage.rawValue
    @AppStorage(GenerationController.keepAliveMinutesKey) private var keepAliveMinutes = GenerationController.defaultKeepAliveMinutes
    @AppStorage(GenerationController.wordTimingKey) private var wordTiming = true
    @AppStorage(AppPreferences.userLanguageKey) private var userLanguage = AppPreferences.defaultUserLanguage.rawValue
    @State private var modelsSize: Int64?
    @State private var framesSize: Int64?
    @Environment(\.controlActiveState) private var controlActiveState

    /// 고정 언어(한국어·일본어·영어). 예전 값("auto", "zh")은 기본 언어로 보인다.
    private static let languages: [(code: String, label: String)] = Language.allCases.map { ($0.rawValue, $0.displayName) }

    private var shownKeepAlive: Int {
        GenerationController.keepAliveChoices.contains(keepAliveMinutes) ? keepAliveMinutes : GenerationController.defaultKeepAliveMinutes
    }

    private static func keepAliveLabel(_ minutes: Int) -> String {
        let text = minutes >= 60 ? "\(minutes / 60)시간" : "\(minutes)분"
        return minutes == GenerationController.defaultKeepAliveMinutes ? "\(text) (기본)" : text
    }

    private var shownLanguage: String {
        (Language(rawValue: sourceLanguage) ?? GenerationController.defaultSourceLanguage).displayName
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("일반", systemImage: "gearshape") }
            transcriptionTab
                .tabItem { Label("받아쓰기", systemImage: "mic") }
            LLMSettingsView()
                .tabItem { Label("LLM", systemImage: "cpu") }
            storageTab
                .tabItem { Label("저장 공간", systemImage: "internaldrive") }
        }
        .frame(width: 540, height: 560)
    }

    private var shownUserLanguage: String {
        (Language(rawValue: userLanguage) ?? AppPreferences.defaultUserLanguage).displayName
    }

    private var generalTab: some View {
        SettingsPage {
            SettingsGroup("일반") {
                SettingsRow("내 언어") {
                    VStack(alignment: .leading, spacing: 4) {
                        JMenuButton(items: {
                            Self.languages.map { item in (item.label, { userLanguage = item.code }) }
                        }) {
                            Text(shownUserLanguage)
                        }
                        .accessibilityLabel("내 언어")
                        .accessibilityValue(shownUserLanguage)
                        Text("원문 검토가 원문 수정 제안의 뜻을 이 언어로 함께 보여 줘요. 작품 원어와 같으면 보여 주지 않아요.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.text3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var transcriptionTab: some View {
        SettingsPage {
            SettingsGroup("받아쓰기") {
                SettingsRow("받아쓰기 모델") {
                    JMenuButton(items: {
                        Transcriber.models.map { option in (option.displayName, { modelID = option.id }) }
                    }) {
                        Text(Transcriber.models.first { $0.id == modelID }?.displayName ?? modelID)
                    }
                    .accessibilityLabel("받아쓰기 모델")
                    .accessibilityValue(Transcriber.models.first { $0.id == modelID }?.displayName ?? modelID)
                }
                SettingsRow("원문 언어") {
                    JMenuButton(items: {
                        Self.languages.map { item in (item.label, { sourceLanguage = item.code }) }
                    }) {
                        Text(shownLanguage)
                    }
                    .accessibilityLabel("원문 언어")
                    .accessibilityValue(shownLanguage)
                }
                SettingsRow("시간 맞추기") {
                    VStack(alignment: .leading, spacing: 4) {
                        JMenuButton(items: {
                            [(Self.wordTimingLabel(true), { wordTiming = true }),
                             (Self.wordTimingLabel(false), { wordTiming = false })]
                        }) {
                            Text(Self.wordTimingLabel(wordTiming))
                        }
                        .accessibilityLabel("시간 맞추기")
                        .accessibilityValue(Self.wordTimingLabel(wordTiming))
                        Text("정밀하게 하면 단어 단위로 시간을 재서 조각을 실제 말에 맞추고, 말 사이가 길게 비면 조각을 나눠요. 받아쓰기가 조금 느려져요.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.text3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                SettingsRow("모델 유지 시간") {
                    VStack(alignment: .leading, spacing: 4) {
                        JMenuButton(items: {
                            GenerationController.keepAliveChoices.map { minutes in
                                (Self.keepAliveLabel(minutes), { keepAliveMinutes = minutes })
                            }
                        }) {
                            Text(Self.keepAliveLabel(shownKeepAlive))
                        }
                        .accessibilityLabel("모델 유지 시간")
                        .accessibilityValue(Self.keepAliveLabel(shownKeepAlive))
                        Text("구간 다시 받아쓰기 뒤 받아쓰기 모델을 메모리에 두는 시간이에요. 길수록 다음 구간 작업이 바로 시작되지만 메모리를 그만큼 오래 써요.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.text3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    static func wordTimingLabel(_ on: Bool) -> String { on ? "정밀하게(단어 기준)" : "기본(문장 기준)" }

    private var storageTab: some View {
        SettingsPage {
            // 크기 글은 값이 바뀔 때 새로 만든다(그대로 두면 접근성 값이 갱신되지 않았다).
            SettingsGroup("저장 공간") {
                SettingsRow("받은 모델") {
                    HStack(spacing: 10) {
                        Text(Self.format(modelsSize)).monospacedDigit().id(modelsSize)
                        Spacer(minLength: 0)
                        Button("받은 모델 지우기") {
                            Task {
                                await model.perform { try await generation.deleteDownloadedModels() }
                                await refresh()
                            }
                        }
                        .buttonStyle(.jSecondary)
                        .disabled(generation.isRunning || (modelsSize ?? 0) == 0)
                    }
                }
                SettingsRow("프레임 캐시") {
                    HStack(spacing: 10) {
                        Text(Self.format(framesSize)).monospacedDigit().id(framesSize)
                        Spacer(minLength: 0)
                        Button("프레임 캐시 지우기") {
                            Task {
                                await model.perform { try await model.clearFrameCaches() }
                                await refresh()
                            }
                        }
                        .buttonStyle(.jSecondary)
                        .disabled(generation.isRunning || (framesSize ?? 0) == 0)
                    }
                }
            }
            if generation.isRunning {
                Text("자막을 만드는 중에는 지울 수 없어요.")
                    .settingsHint()
            }
        }
        // 설정 창은 닫아도 뷰가 남아 있으니, 창이 앞으로 올 때와 생성이 끝날 때마다 다시 잰다.
        .task(id: generation.isRunning) { await refresh() }
        .onChange(of: controlActiveState) { _, state in
            if state == .key { Task { await refresh() } }
        }
    }

    private func refresh() async {
        let models = GenerationController.modelsFolder
        let projects = AppModel.defaultRoot()
        let (m, f) = await Task.detached(priority: .utility) {
            (Self.size(of: models), Self.framesSize(in: projects))
        }.value
        modelsSize = m
        framesSize = f
    }

    private static func format(_ bytes: Int64?) -> String {
        guard let bytes else { return "계산 중…" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// 폴더 안 파일 크기 합계. 없으면 0.
    nonisolated private static func size(of folder: URL) -> Int64 {
        guard let items = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in items {
            guard let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// 모든 프로젝트의 `frames/` 합계.
    nonisolated private static func framesSize(in projects: URL) -> Int64 {
        let folders = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        return folders.reduce(0) { $0 + size(of: $1.appendingPathComponent(AppModel.framesFolderName, isDirectory: true)) }
    }
}

// MARK: - 설정 화면 공용 조각(시안 .set-body, .group, .box, .row2, .hint)

/// 설정 탭 한 장: bg1 바탕에 세로로 쌓는 스크롤 화면.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content() }
                .padding(EdgeInsets(top: 20, leading: 26, bottom: 26, trailing: 26))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.bg1)
    }
}

/// 작은 제목(h5)과 그 아래 bg2 상자.
struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text3)
                .padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.bg2, in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line, lineWidth: 1) }
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// 상자 안 한 줄: 왼쪽 라벨 110, 오른쪽 내용. 아래에 구분선(마지막 줄 선은 상자 테두리와 겹친다).
struct SettingsRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text2)
                .frame(width: 110, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

extension View {
    /// 시안 .hint: text3 11pt, 줄 간격 넉넉하게.
    func settingsHint() -> some View {
        font(.system(size: 11))
            .foregroundStyle(Theme.text3)
            .lineSpacing(3)
            .padding(.horizontal, 4)
            .fixedSize(horizontal: false, vertical: true)
    }
}
