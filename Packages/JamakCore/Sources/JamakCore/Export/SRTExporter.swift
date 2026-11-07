import Foundation

/// 자막셋 하나를 언어마다 srt 파일로 내보낸다.
public enum SRTExporter {
    /// `<영상 이름(마지막 확장자 제외)>.<언어코드>.srt`
    public static func fileName(videoName: String, language: Language) -> String {
        let base = (videoName as NSString).deletingPathExtension
        return "\(base).\(language.rawValue).srt"
    }

    /// 이미 있는 내보내기 대상 파일. `languages` 순서를 따른다.
    public static func conflicts(languages: [Language], videoName: String, in folder: URL) -> [URL] {
        languages.map { folder.appendingPathComponent(fileName(videoName: videoName, language: $0)) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 언어마다 srt(`CueSRT.export`)를 UTF-8로 원자적으로 쓴다. 기존 파일은 덮어쓴다. `languages` 순서로 돌려준다.
    public static func export(_ set: CueSet, languages: [Language], original: Language, fallback: Bool,
                              videoName: String, to folder: URL) throws -> [URL] {
        try languages.map { language in
            let url = folder.appendingPathComponent(fileName(videoName: videoName, language: language))
            try Data(CueSRT.export(set, language: language, original: original, fallback: fallback).utf8).write(to: url, options: .atomic)
            return url
        }
    }
}
