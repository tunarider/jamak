import Foundation

/// 자막을 넣은 영상 내보내기의 파일 이름 규칙.
public enum VideoExport {
    public static func fileExtension(_ container: SubtitleContainer) -> String {
        container == .mkv ? "mkv" : "mp4"
    }

    /// `<영상 이름(마지막 확장자 제외)>.subs.<mkv|mp4>`
    public static func defaultFileName(videoName: String, container: SubtitleContainer) -> String {
        let base = (videoName as NSString).deletingPathExtension
        return "\(base).subs.\(fileExtension(container))"
    }

    /// 만드는 동안 `folder`에 두는 임시 파일. 확장자는 그대로 마지막에 둔다(ffmpeg가 확장자로 형식을 고른다).
    /// 샌드박스는 저장 패널이 고른 파일 하나만 열어 주므로 `output` 옆이 아니라 앱 임시 폴더에 만든다.
    public static func partialURL(for output: URL, in folder: URL) -> URL {
        let ext = output.pathExtension
        let base = output.deletingPathExtension().lastPathComponent
        return folder.appendingPathComponent("\(base).partial.\(ext)")
    }

    /// 영상에 넣을 자막 트랙 하나(언어 하나).
    public struct Track: Equatable, Sendable {
        public let language: Language
        /// 트랙 이름(언어 표시 이름). 언어 태그(kor/jpn/eng)는 `FFmpegCommand.muxSubtitles`가 언어 코드로 만든다.
        public let title: String
        /// 종류 부호가 붙은 srt 본문
        public let srt: String
    }

    /// 자막셋 하나의 `languages`마다 트랙 하나. 순서는 `languages`를 따른다.
    public static func tracks(for set: CueSet, languages: [Language], original: Language, fallback: Bool) -> [Track] {
        languages.map {
            Track(language: $0, title: $0.displayName,
                  srt: CueSRT.export(set, language: $0, original: original, fallback: fallback))
        }
    }
}
