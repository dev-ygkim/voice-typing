import Foundation
import Observation
import WhisperKit
import os

/// Whisper 음성 인식 모델. 처음 한 번 내려받고, 앱을 켤 때마다 불러온다.
/// 받아쓰기는 모두 Mac 안에서 하며 소리는 밖으로 나가지 않는다 (인터넷은 모델을 받을 때만 쓴다).
@Observable
final class SpeechModel {
    enum State: Equatable {
        /// 받아 둔 모델을 불러오는 중. 처음 한 번은 Neural Engine 용 준비로 30초쯤 걸린다.
        case loading
        /// 아직 내려받지 않음 → [음성 모델 내려받기] 버튼
        case missing
        /// 내려받는 중 (0...1)
        case downloading(Double)
        case ready
        case failed(String)
    }

    /// OpenAI Whisper large-v3-turbo (2024-09-30 공개판). 한국어 정확도와 속도의 균형이 좋다.
    static let variant = "openai_whisper-large-v3-v20240930"
    static let downloadSize = "약 1.6GB"
    /// ~/Library/Application Support/VoiceTyping
    static let defaultBase = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "VoiceTyping")
    /// 다운로드가 끝까지 완료됐다는 표시 파일. 중간에 끊긴 다운로드를 설치된 것으로 착각하지 않게 한다.
    private static let marker = ".voicetyping-complete"
    // 확인: /usr/bin/log show --last 10m --predicate 'subsystem == "local.voicetyping"'
    private static let log = Logger(subsystem: "local.voicetyping", category: "model")

    private(set) var state = State.loading
    let base: URL
    /// WhisperKit 이 모델을 내려받는 위치
    var folder: URL { base.appending(path: "models/argmaxinc/whisperkit-coreml/\(Self.variant)") }
    @ObservationIgnored private var pipe: WhisperKit?

    init(base: URL = SpeechModel.defaultBase) {
        self.base = base
    }

    static func isInstalled(at folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appending(path: marker).path)
    }

    static func markInstalled(at folder: URL) {
        FileManager.default.createFile(atPath: folder.appending(path: marker).path, contents: nil)
    }

    /// 앱을 켤 때: 받아 둔 모델이 있으면 불러오고, 없으면 내려받기 버튼을 보여 준다.
    @MainActor
    func prepare() async {
        guard Self.isInstalled(at: folder) else {
            state = .missing
            return
        }
        await load()
    }

    /// [음성 모델 내려받기] 버튼. 받은 뒤 바로 불러온다.
    @MainActor
    func download() async {
        state = .downloading(0)
        do {
            let downloaded = try await WhisperKit.download(variant: Self.variant, downloadBase: base) { progress in
                DispatchQueue.main.async {
                    guard case .downloading = self.state else { return }   // 끝난 뒤 늦게 온 진행률은 무시
                    self.state = .downloading(progress.fractionCompleted)
                }
            }
            Self.markInstalled(at: downloaded)
        } catch {
            Self.log.error("다운로드 실패: \(error.localizedDescription, privacy: .public)")
            state = .failed("모델을 내려받지 못했습니다. 인터넷 연결을 확인하고 다시 시도해 주세요")
            return
        }
        await load()
    }

    @MainActor
    private func load() async {
        state = .loading
        do {
            let config = WhisperKitConfig(downloadBase: base, modelFolder: folder.path, verbose: false,
                                          logLevel: .error, prewarm: true, load: true, download: false)
            pipe = try await WhisperKit(config)
            state = .ready
        } catch {
            Self.log.error("불러오기 실패: \(error.localizedDescription, privacy: .public)")
            state = .failed("모델을 불러오지 못했습니다. 다시 내려받아 주세요")
        }
    }

    /// 받아쓰기 설정. 한국어로 고정한다.
    /// 용어 힌트(promptTokens)는 합성 음성에선 영어 철자를 살렸지만 실제 목소리에선 빈 결과를 내서 쓰지 않는다.
    /// Whisper 는 자신 없으면 온도를 올려 다시 시도한다(최대 5번). 실시간 받아쓰기는 빨라야 해서 다시 시도하지 않는다.
    static func options(final: Bool) -> DecodingOptions {
        DecodingOptions(language: "ko", temperatureFallbackCount: final ? 5 : 0)
    }

    /// 최대 진폭을 0.9 로 맞춘다. AirPods 통화 모드처럼 작게(-40dB) 들어온 목소리를 키우면
    /// Whisper 가 더 빨리, 더 자신 있게 알아듣는다 (실측: 3.7초 → 0.8초).
    /// 잡음을 지나치게 키우지 않도록 최대 30dB(31.6배)까지만 키운다.
    // ponytail: 가장 큰 한 점 기준이라 "딱" 소리 하나가 있으면 덜 키워진다. 그런 녹음이 잦으면 RMS 기준으로 바꾼다.
    static func normalized(_ samples: [Float]) -> [Float] {
        let peak = samples.map(abs).max() ?? 0
        guard peak > 0 else { return samples }
        let gain = min(0.9 / peak, 31.6)
        return samples.map { $0 * gain }
    }

    /// 한글로 받아쓴 개발 용어 → 영어 철자. 긴 것부터 바꾼다.
    // ponytail: 고정 목록. 자주 한글로 나오는 용어가 보이면 여기에 추가한다.
    static let terms: [(korean: String, english: String)] = [
        ("클로드 코드", "Claude Code"), ("클로드코드", "Claude Code"), ("클로드", "Claude"),
        ("풀 리퀘스트", "pull request"), ("풀리퀘스트", "pull request"),
        ("커밋", "commit"), ("푸시", "push"), ("푸쉬", "push"), ("머지", "merge"), ("브랜치", "branch"),
        ("리드미", "README"), ("깃허브", "GitHub"), ("에이피아이", "API"),
        ("타입 스크립트", "TypeScript"), ("타입스크립트", "TypeScript"), ("자바스크립트", "JavaScript"),
        ("파이썬", "Python"), ("스위프트", "Swift"),
    ]

    /// 받아쓴 글에서 한글로 적힌 개발 용어를 영어로 바꾼다.
    /// 앞 글자가 한글이면 다른 낱말의 일부(예: 나머지)이므로 바꾸지 않는다. 뒤에 붙는 조사(하고, 에서)는 그대로 둔다.
    static func englishTerms(_ text: String) -> String {
        var result = text
        for (korean, english) in terms {
            let pattern = "(?<![가-힣])" + NSRegularExpression.escapedPattern(for: korean)
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                    withTemplate: NSRegularExpression.escapedTemplate(for: english))
        }
        return result
    }

    /// 16kHz 1채널 소리를 받아쓴다. 실패하면 빈 문자열.
    func transcribe(_ samples: [Float], final: Bool) async -> String {
        guard let pipe, !samples.isEmpty else { return "" }
        do {
            let results = try await pipe.transcribe(audioArray: Self.normalized(samples), decodeOptions: Self.options(final: final))
            return Self.englishTerms(results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            Self.log.error("받아쓰기 실패: \(error.localizedDescription, privacy: .public)")
            return ""
        }
    }
}
