import AVFoundation
import Foundation
import Testing
import WhisperKit
@testable import VoiceTyping

struct SpeechModelTests {
    func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "voicetyping-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("모델을 내려받은 적이 없으면 설치되지 않은 것으로 본다")
    func missingWhenEmpty() throws {
        #expect(!SpeechModel.isInstalled(at: try tempFolder()))
    }

    @Test("다운로드가 끝까지 완료된 모델만 설치된 것으로 본다 (중간에 끊긴 다운로드 제외)")
    func installedOnlyAfterComplete() throws {
        let folder = try tempFolder()
        try Data().write(to: folder.appending(path: "AudioEncoder.mlmodelc"))   // 일부 파일만 받은 상태
        #expect(!SpeechModel.isInstalled(at: folder))
        SpeechModel.markInstalled(at: folder)
        #expect(SpeechModel.isInstalled(at: folder))
    }

    @Test("앱을 처음 켜면 모델이 없으니 내려받기 버튼 상태가 된다")
    @MainActor
    func firstLaunchShowsDownload() async throws {
        let model = SpeechModel(base: try tempFolder())
        await model.prepare()
        #expect(model.state == .missing)
    }

    @Test("작은 목소리는 키우고(최대 진폭 0.9) 큰 소리는 줄여 Whisper 가 잘 알아듣게 한다")
    func normalizesVolume() throws {
        let quiet = (0..<1_600).map { Float(sin(Double($0) * 0.1)) * 0.05 }
        let loud = quiet.map { $0 * 19 }
        for input in [quiet, loud] {
            let peak = SpeechModel.normalized(input).map(abs).max() ?? 0
            #expect(abs(peak - 0.9) < 0.01)
        }
    }

    @Test("무음은 키우지 않고, 아주 작은 소리도 30dB 넘게 키우지 않는다 (잡음 증폭 방지)")
    func normalizeLimits() {
        #expect(SpeechModel.normalized([0, 0, 0]) == [0, 0, 0])
        let peak = SpeechModel.normalized([0.001, -0.001]).map(abs).max() ?? 0
        #expect(peak <= 0.001 * 31.7)
    }

    @Test("한국어로 고정하고, 실제 목소리에서 빈 결과를 내던 용어 힌트는 쓰지 않는다")
    func decodingOptions() {
        for final in [true, false] {
            let options = SpeechModel.options(final: final)
            #expect(options.language == "ko")
            #expect(options.promptTokens == nil)
        }
    }

    @Test("실시간 받아쓰기는 빠르게 한 번만, 정지 후 마지막 받아쓰기는 자신 없으면 다시 시도한다")
    func retriesOnlyWhenFinal() {
        #expect(SpeechModel.options(final: false).temperatureFallbackCount == 0)
        #expect(SpeechModel.options(final: true).temperatureFallbackCount > 0)
    }

    @Test("한글로 받아쓴 개발 용어를 영어 철자로 바꾼다")
    func englishTerms() {
        #expect(SpeechModel.englishTerms("오늘 클로드 코드에서 커밋하고 푸시한 다음에 풀 리퀘스트 만들어줘.")
                == "오늘 Claude Code에서 commit하고 push한 다음에 pull request 만들어줘.")
        #expect(SpeechModel.englishTerms("리드미 파일이랑 타입 스크립트 타입 에러 있으면 고쳐줘.")
                == "README 파일이랑 TypeScript 타입 에러 있으면 고쳐줘.")
    }

    @Test("다른 낱말 속에 들어 있는 글자는 바꾸지 않는다 (나머지 ≠ 나merge)")
    func englishTermsKeepKoreanWords() {
        #expect(SpeechModel.englishTerms("나머지는 그대로 둬") == "나머지는 그대로 둬")
    }

    /// 실제 모델로 한영 혼용 문장을 받아쓴다. 모델 파일이 필요해 평소에는 건너뛴다.
    /// 실행: VOICETYPING_MODEL_BASE="$HOME/Library/Application Support/VoiceTyping" swift test --filter SpeechModelTests
    @Test("마이크와 같은 경로(4096개씩 나눠 16kHz 변환)로 한영 혼용 문장을 받아쓴다",
          .enabled(if: ProcessInfo.processInfo.environment["VOICETYPING_MODEL_BASE"] != nil),
          arguments: [48_000, 24_000])   // 내장 마이크, AirPods 통화 모드
    @MainActor
    func transcribesMixedSpeech(sampleRate: Int) async throws {
        let base = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VOICETYPING_MODEL_BASE"]))
        let model = SpeechModel(base: base)
        await model.prepare()
        #expect(model.state == .ready)

        // macOS 한국어 음성(유나)으로 시험 문장을 만든다
        let file = try tempFolder().appending(path: "mixed.caf")   // Float32 는 CAF 로만 저장된다
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Yuna", "--data-format=LEF32@\(sampleRate)", "-o", file.path,
                         "오늘 Claude Code에서 commit 하고 push 한 다음에 pull request 만들어 줘."]
        try say.run()
        say.waitUntilExit()
        try #require(say.terminationStatus == 0)

        // 마이크 탭처럼 4096개씩 나눠 같은 변환기로 차례로 바꾼다
        let audio = try AVAudioFile(forReading: file)
        let converter = try #require(AVAudioConverter(from: audio.processingFormat, to: Transcriber.whisperFormat))
        var samples: [Float] = []
        while audio.framePosition < audio.length {
            let chunk = try #require(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4096))
            try audio.read(into: chunk, frameCount: 4096)
            samples += Transcriber.resample(chunk, with: converter)
        }
        let text = await model.transcribe(samples, final: true)

        #expect(text.contains("Claude"))
        #expect(text.localizedCaseInsensitiveContains("commit"))
        #expect(text.localizedCaseInsensitiveContains("push"))
    }
}
