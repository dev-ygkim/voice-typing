import AVFoundation
import Observation
import os

/// 인식 결과를 모아 화면에 보여 줄 텍스트를 만든다. 마이크·OS와 무관한 순수 로직이라 단위 테스트한다.
struct TranscriptBuffer: Equatable {
    /// 확정된 텍스트. 사용자가 직접 고친 내용도 여기에 들어간다.
    var text = ""
    /// 지금 말하는 중인 발화의 미확정 텍스트 (화면에 회색으로 표시)
    private(set) var partial = ""
    /// 이번 녹음에서 마지막으로 확정된 발화의 인식 원문
    private var lastUtterance = ""

    /// 확정 + 미확정을 합친 화면용 텍스트
    var display: String { Self.join(text, partial) }

    /// 클립보드로 보낼 텍스트. 끝의 줄바꿈이 터미널에서 Enter 로 처리되지 않도록 앞뒤 공백·줄바꿈을 자른다.
    var outgoing: String { display.trimmingCharacters(in: .whitespacesAndNewlines) }

    var isEmpty: Bool { outgoing.isEmpty }

    /// 인식기 결과 하나를 반영한다.
    /// - Parameter utteranceEnded: 발화 하나가 끝났다는 신호 (isFinal 또는 speechRecognitionMetadata 가 있을 때)
    mutating func update(_ recognized: String, utteranceEnded: Bool) {
        var current = recognized
        // 인식기에 따라 다음 발화 결과 앞에 이전 발화를 다시 붙여 보낸다. 그 부분만 잘라 중복을 막는다.
        // ponytail: 글자가 똑같은 접두어만 자른다. 같은 녹음 안에서 직전 발화와 똑같은 말로 시작하면
        //           그 부분이 빠질 수 있다. 실사용에서 보이면 인식 결과의 시간 정보로 판단하도록 바꾼다.
        if !lastUtterance.isEmpty, current.hasPrefix(lastUtterance) {
            current = String(current.dropFirst(lastUtterance.count)).trimmingCharacters(in: .whitespaces)
        }
        if utteranceEnded {
            text = Self.join(text, current)
            partial = ""
            lastUtterance = recognized
        } else {
            partial = current
        }
    }

    /// 녹음을 멈출 때 부른다. 화면에 보이던 미확정 텍스트를 그대로 확정한다.
    mutating func endSession() {
        text = Self.join(text, partial)
        partial = ""
        lastUtterance = ""
    }

    mutating func clear() { self = TranscriptBuffer() }

    /// 두 텍스트를 공백 하나로 잇는다. 앞 텍스트가 공백·줄바꿈으로 끝나면 공백을 더하지 않는다.
    static func join(_ head: String, _ tail: String) -> String {
        guard !tail.isEmpty else { return head }
        guard let last = head.last, !last.isWhitespace else { return head + tail }
        return head + " " + tail
    }
}

/// 마이크 소리를 온디바이스 한국어 인식기로 넘기고, 결과를 TranscriptBuffer 에 모은다.
@Observable
final class Transcriber {
    enum State: Equatable {
        case idle
        case recording
        /// 정지를 눌러 마이크는 껐고, 마지막 받아쓰기를 기다리는 중
        case finishing
        /// 녹음을 시작하지 못함. settings 가 있으면 시스템 설정의 해당 화면을 열 수 있다.
        case failed(String, settings: URL?)
    }

    /// Whisper 가 받는 소리 형식: 16kHz 1채널
    static let whisperFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    static let microphoneSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")

    var buffer = TranscriptBuffer()
    private(set) var state = State.idle
    private(set) var startedAt = Date()
    /// 최근 마이크 음량 (0...1). 녹음 중 파형 막대로 보여 준다.
    private(set) var levels = [Float](repeating: 0, count: 24)
    /// 마이크 소리가 실제로 들어오기 시작했는지. AirPods 는 버튼을 누르고 1초 넘게 지나야 소리가 들어온다.
    private(set) var listening = false

    @ObservationIgnored let model: SpeechModel
    @ObservationIgnored private var engine = AVAudioEngine()
    @ObservationIgnored private var samples: [Float] = []       // 이번 녹음의 소리 (16kHz)
    @ObservationIgnored private var transcribed = 0              // 마지막 실시간 받아쓰기 때의 samples 길이
    @ObservationIgnored private var live: Task<Void, Never>?     // 진행 중인 실시간 받아쓰기 (한 번에 하나만)
    @ObservationIgnored private var session = 0       // 끝난 녹음의 늦은 콜백을 버리는 데 쓴다
    @ObservationIgnored private var starting = false  // 권한 확인 중 버튼을 또 눌러도 두 번 시작하지 않게
    @ObservationIgnored private var restarts = 0      // 이번 녹음에서 마이크 형식이 바뀌어 다시 시작한 횟수
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var heard = 0         // 진단용: 이번 녹음에 받은 오디오 버퍼 수
    @ObservationIgnored private var loudest: Float = 0 // 이번 녹음의 최대 음량. 무음 판정에도 쓴다.
    // 진단용: 길이·음량만 남기고 받아쓴 내용은 남기지 않는다
    // 확인: /usr/bin/log show --last 10m --predicate 'subsystem == "local.voicetyping"'
    private static let log = Logger(subsystem: "local.voicetyping", category: "speech")

    init(model: SpeechModel) {
        self.model = model
    }

    var isRecording: Bool { state == .recording }
    /// 녹음 중이거나 마무리 중 — 이때는 편집·복사·새 녹음을 막는다
    var isBusy: Bool { state == .recording || state == .finishing }

    func toggle() {
        if isRecording { stop(); return }
        guard state != .finishing, !starting else { return }
        starting = true
        Task { @MainActor in
            await start()
            starting = false
        }
    }

    @MainActor
    private func start() async {
        guard model.state == .ready else { return }   // 녹음 버튼은 모델이 준비된 뒤에만 눌린다
        if await !AVCaptureDevice.requestAccess(for: .audio) {
            state = .failed("마이크 권한이 필요합니다", settings: Self.microphoneSettings)
            return
        }
        session += 1
        samples = []
        transcribed = 0
        restarts = 0
        heard = 0
        loudest = 0
        listening = false
        startedAt = Date()
        begin()
    }

    /// 마이크를 연다. 마이크 형식이 바뀌어 다시 열 때도 쓰며, 소리는 같은 녹음(samples)에 이어서 담는다.
    private func begin() {
        // 녹음마다 엔진을 새로 만든다. AirPods 처럼 장치가 바뀌어도 지금의 하드웨어 형식을 읽게 하기 위함이다.
        engine = AVAudioEngine()
        let input = engine.inputNode
        // 탭 형식은 마이크 하드웨어 형식(inputFormat)을 쓴다. outputFormat 은 출력 장치(예: HDMI 48kHz)를 따라가서
        // AirPods 마이크(24kHz)와 어긋나면 installTap 이 "Input HW format and tap format not matching" 예외로 실패한다.
        let format = input.inputFormat(forBus: 0)
        Self.log.notice("마이크 형식: \(format.sampleRate)Hz \(format.channelCount)ch")
        guard format.channelCount > 0, format.sampleRate > 0,
              let converter = AVAudioConverter(from: format, to: Self.whisperFormat) else {
            fail("마이크를 찾을 수 없습니다")
            return
        }
        let current = session
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] pcm, _ in
            let chunk = Self.resample(pcm, with: converter)
            let level = Self.level(of: pcm)
            DispatchQueue.main.async { self?.receive(chunk, level: level, session: current) }
        }
        // AirPods 는 마이크를 여는 순간 음질 모드를 바꿔 형식이 바뀐다(예: 48kHz → 24kHz).
        // 그러면 엔진이 스스로 멈춰 소리가 끊기므로, 새 형식으로 다시 연다. 시작 직후 바뀌므로 시작 전에 등록한다.
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.deviceChanged(session: current) }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            fail("마이크를 시작하지 못했습니다: \(error.localizedDescription)")
            return
        }
        state = .recording
    }

    private func receive(_ chunk: [Float], level: Float, session current: Int) {
        guard session == current else { return }
        if heard == 0 {
            Self.log.notice("첫 소리 도착: 녹음 버튼 +\(Date().timeIntervalSince(self.startedAt))초")
            listening = true
        }
        samples += chunk
        heard += 1
        loudest = max(loudest, level)
        guard isRecording else { return }
        levels.removeFirst()
        levels.append(level)
        tick()
    }

    /// 소리가 들어올 때마다: 새 소리가 쌓였고 이전 받아쓰기가 끝났으면 지금까지의 녹음을 다시 받아써
    /// 화면 글자를 바꾼다 (회색 = 아직 바뀔 수 있음). 타이머 대신 소리 도착에 묶어 마이크를 다시 열어도 멈추지 않는다.
    // ponytail: 매번 녹음 전체를 다시 받아쓴다. 1~2분을 넘는 긴 녹음에서는 갱신이 느려진다.
    //           그런 사용이 잦으면 확정된 앞부분은 빼고 뒷부분만 받아쓰도록 바꾼다.
    private func tick() {
        guard Self.hasSpeech(loudest: loudest),
              Self.shouldTranscribe(pending: samples.count - transcribed, busy: live != nil) else { return }
        let snapshot = samples
        let current = session
        let began = Date()
        live = Task { @MainActor in
            let text = await model.transcribe(snapshot, final: false)
            live = nil
            Self.log.notice("실시간 받아쓰기: 소리 \(Double(snapshot.count) / 16_000)초 → \(Date().timeIntervalSince(began))초 걸림")
            guard session == current, isRecording else { return }
            transcribed = snapshot.count
            buffer.update(text, utteranceEnded: false)
        }
    }

    enum DeviceChange: Equatable {
        case restart
        case fail(String, settings: URL?)
    }

    static let maxRestarts = 3
    static let unstableDeviceMessage = "마이크 장치가 계속 바뀌어 녹음을 멈췄습니다. 잠시 후 다시 시도해 주세요"

    /// 녹음 중 마이크 형식이 바뀌었을 때 할 일. 녹음 중이 아니면 nil(무시).
    static func onDeviceChange(recording: Bool, restarts: Int) -> DeviceChange? {
        guard recording else { return nil }
        return restarts < maxRestarts ? .restart : .fail(unstableDeviceMessage, settings: nil)
    }

    private func deviceChanged(session current: Int) {
        guard session == current else { return }
        let format = engine.inputNode.inputFormat(forBus: 0)
        Self.log.notice("마이크 형식 변경: \(format.sampleRate)Hz, 재시작 \(self.restarts)회째")
        switch Self.onDeviceChange(recording: isRecording, restarts: restarts) {
        case nil:
            return
        case .restart:
            restarts += 1
            closeMicrophone()
            begin()                           // 새 형식으로 열어 같은 녹음에 이어서 담는다
        case .fail(let message, let settings):
            fail(message, settings: settings)
        }
    }

    /// 정지 버튼: 마이크를 끄고, 녹음 전체를 마지막으로 받아써 확정한다.
    func stop() {
        guard isRecording else { return }
        Self.log.notice("정지: 녹음 \(Date().timeIntervalSince(self.startedAt))초, 받은 소리 \(Double(self.samples.count) / 16_000)초")
        closeMicrophone()
        state = .finishing
        let current = session
        let pending = live
        Task { @MainActor in
            await pending?.value              // 같은 모델을 동시에 쓰지 않도록 실시간 받아쓰기가 끝나길 기다린다
            guard session == current else { return }
            if Self.hasSpeech(loudest: loudest) {
                let text = await model.transcribe(samples, final: true)
                guard session == current else { return }
                buffer.update(text, utteranceEnded: false)
            }
            finish()
        }
    }

    private func closeMicrophone() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        levels = [Float](repeating: 0, count: levels.count)
    }

    /// 녹음을 끝내고 화면에 보이던 내용을 확정한다
    private func finish() {
        closeMicrophone()
        session += 1                          // 이후 도착하는 콜백은 무시
        Self.log.notice("오디오 버퍼 \(self.heard)개, 최대 음량 \(self.loudest), 길이 \(Double(self.samples.count) / 16_000)초")
        // 인식률 튜닝용. 평소에는 꺼져 있고, 켜면 녹음마다 Mac 안(모델 폴더의 recordings)에 저장한다.
        // 켜기: defaults write local.voicetyping.VoiceTyping SaveRecordings -bool YES
        if UserDefaults.standard.bool(forKey: "SaveRecordings"), !samples.isEmpty {
            let folder = model.base.appending(path: "recordings")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? Self.save(samples, to: folder.appending(path: Self.recordingName(at: Date())))
        }
        samples = []
        buffer.endSession()
        state = .idle
    }

    private func fail(_ message: String, settings: URL? = nil) {
        finish()
        state = .failed(message, settings: settings)
    }

    /// 거의 무음인 녹음은 받아쓰지 않는다. Whisper 는 무음에서 없는 말("감사합니다" 등)을 지어내곤 한다.
    // ponytail: 고정 기준. 조용히 말해도 안 받아써지면 낮춘다 (진단 로그의 "최대 음량" 참고).
    static func hasSpeech(loudest: Float) -> Bool { loudest >= 0.05 }

    /// 새 소리가 0.5초 이상 쌓였고 이전 받아쓰기가 끝났을 때만 실시간 받아쓰기를 한다.
    static func shouldTranscribe(pending: Int, busy: Bool) -> Bool { !busy && pending >= 8_000 }

    static func recordingName(at date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = timeZone
        return "recording-\(formatter.string(from: date)).wav"
    }

    /// 16kHz 소리를 WAV 파일로 저장한다.
    static func save(_ samples: [Float], to url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: whisperFormat.settings)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: whisperFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        pcm.frameLength = pcm.frameCapacity
        samples.withUnsafeBufferPointer { pcm.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: pcm)
    }

    /// 마이크 버퍼 하나를 Whisper 형식(16kHz 1채널)으로 바꾼다.
    /// 변환기는 녹음 동안 하나를 계속 써서 버퍼 경계가 매끄럽고, 입력은 한 번만 넘겨 소리가 중복되지 않는다.
    static func resample(_ pcm: AVAudioPCMBuffer, with converter: AVAudioConverter) -> [Float] {
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(pcm.frameLength) * ratio).rounded(.up)) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return [] }
        var given = false
        let status = converter.convert(to: out, error: nil) { _, inputStatus in
            if given {
                inputStatus.pointee = .noDataNow
                return nil
            }
            given = true
            inputStatus.pointee = .haveData
            return pcm
        }
        guard status != .error, let data = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
    }

    /// 소리 버퍼 하나의 음량(RMS)을 0...1 로 바꾼다.
    static func level(of pcm: AVAudioPCMBuffer) -> Float {
        guard let samples = pcm.floatChannelData?[0], pcm.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(pcm.frameLength) { sum += samples[i] * samples[i] }
        let rms = (sum / Float(pcm.frameLength)).squareRoot()
        // ponytail: 말소리 RMS 는 보통 0.01~0.1 이라 10배 키워 막대 높이에 맞춘다. 막대가 너무 작거나 크면 조정
        return min(1, rms * 10)
    }
}

// 상태는 모두 메인 스레드에서만 바꾼다 (마이크 탭은 static 함수만 부르고 메인으로 넘긴다).
// 알림·타이머 콜백이 self 를 메인 큐에서 다시 부르므로 Sendable 검사를 이 약속으로 대신한다.
extension Transcriber: @unchecked Sendable {}
