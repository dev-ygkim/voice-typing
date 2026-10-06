import AVFoundation
import Foundation
import Testing
@testable import VoiceTyping

struct TranscriberTests {
    /// 진폭이 일정한 1채널 소리 버퍼
    func pcm(amplitude: Float, sampleRate: Double = 48_000, frames: AVAudioFrameCount = 480) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.floatChannelData?[0])
        for i in 0..<Int(frames) { samples[i] = i.isMultiple(of: 2) ? amplitude : -amplitude }
        return buffer
    }

    @Test("무음이면 음량은 0")
    func silence() throws {
        #expect(Transcriber.level(of: try pcm(amplitude: 0)) == 0)
    }

    @Test("말소리 크기면 0보다 크고 1 이하")
    func speechLevel() throws {
        let level = Transcriber.level(of: try pcm(amplitude: 0.05))
        #expect(level > 0 && level <= 1)
    }

    @Test("아주 큰 소리도 1을 넘지 않는다")
    func clamped() throws {
        #expect(Transcriber.level(of: try pcm(amplitude: 1)) == 1)
    }

    @Test("마이크 소리를 Whisper 형식(16kHz)으로 바꿀 때 중복·누락 없이 길이가 맞는다",
          arguments: [48_000.0, 24_000.0, 16_000.0])
    func resampleKeepsDuration(sampleRate: Double) throws {
        let input = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let converter = try #require(AVAudioConverter(from: input, to: Transcriber.whisperFormat))
        // 0.1초짜리 버퍼 100개 = 10초 → 16kHz 로 160000개.
        // 변환기는 처음에 0.014초쯤 늦게 내보내므로 10초 길이로 재서 0.1% 안에 들면 중복·누락이 없는 것이다.
        var total = 0
        for _ in 0..<100 {
            total += Transcriber.resample(try pcm(amplitude: 0.1, sampleRate: sampleRate, frames: AVAudioFrameCount(sampleRate / 10)),
                                          with: converter).count
        }
        #expect(abs(total - 160_000) <= 160)
    }

    @Test("거의 무음인 녹음은 받아쓰지 않는다 (Whisper 가 무음에서 없는 말을 지어내는 것 방지)")
    func silenceIsNotSpeech() {
        #expect(!Transcriber.hasSpeech(loudest: 0))
        #expect(!Transcriber.hasSpeech(loudest: 0.02))
        #expect(Transcriber.hasSpeech(loudest: 0.3))
    }

    @Test("새 소리가 0.5초 이상 쌓였고 이전 받아쓰기가 끝났을 때만 화면을 갱신한다")
    func liveTranscriptionCadence() {
        #expect(Transcriber.shouldTranscribe(pending: 8_000, busy: false))
        #expect(!Transcriber.shouldTranscribe(pending: 8_000, busy: true))
        #expect(!Transcriber.shouldTranscribe(pending: 1_000, busy: false))
    }

    @Test("튜닝용으로 마지막 녹음을 16kHz WAV 로 저장하고 다시 읽을 수 있다")
    func savesRecording() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "voicetyping-\(UUID().uuidString).wav")
        let samples = (0..<16_000).map { Float(sin(Double($0) * 0.1) * 0.1) }
        try Transcriber.save(samples, to: url)
        let file = try AVAudioFile(forReading: url)
        #expect(file.length == 16_000)
        #expect(file.fileFormat.sampleRate == 16_000)
    }

    @Test("튜닝용 녹음 파일은 녹음 시각으로 이름을 붙여 여러 개를 남긴다")
    func recordingFileName() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-10-06T08:45:01Z"))
        #expect(Transcriber.recordingName(at: date, timeZone: TimeZone(identifier: "Asia/Seoul")!) == "recording-20261006-174501.wav")
    }

    @Test("녹음 중 마이크 형식이 바뀌면(AirPods 모드 전환 등) 녹음을 다시 이어 간다")
    func deviceChangeRestarts() {
        for restarts in 0..<Transcriber.maxRestarts {
            #expect(Transcriber.onDeviceChange(recording: true, restarts: restarts) == .restart)
        }
    }

    @Test("마이크 형식이 너무 자주 바뀌면 무한 재시작 대신 이유를 알린다")
    func deviceChangeGivesUp() {
        #expect(Transcriber.onDeviceChange(recording: true, restarts: Transcriber.maxRestarts)
                == .fail(Transcriber.unstableDeviceMessage, settings: nil))
    }

    @Test("녹음 중이 아닐 때의 장치 변경은 무시한다")
    func deviceChangeIgnoredWhenIdle() {
        #expect(Transcriber.onDeviceChange(recording: false, restarts: 0) == nil)
    }
}
