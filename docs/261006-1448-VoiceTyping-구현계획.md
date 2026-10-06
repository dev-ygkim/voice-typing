# Voice Typing 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 메뉴바 🎙 → 녹음 → 한국어 실시간 텍스트 → [복사] / [복사+붙여넣기]로 Claude Code 입력창에 넣는 macOS 메뉴바 앱을 만든다.

**Architecture:** SwiftPM 실행 타깃 하나에 파일 3개. `Transcriber.swift`(마이크 + 온디바이스 인식 + 순수 로직 `TranscriptBuffer`), `Paster.swift`(클립보드 + 직전 앱에 ⌘V), `VoiceTypingApp.swift`(MenuBarExtra 화면). 빌드 스크립트가 `.app` 번들로 묶어 서명한다.

**Tech Stack:** Swift 6 툴체인 (Swift 5 언어 모드), SwiftUI `MenuBarExtra`, AVFoundation, Speech, AppKit, Swift Testing. 외부 라이브러리 없음.

**Spec:** `docs/261006-1143-음성입력-메뉴바앱-설계안.md`

## Global Constraints

- macOS 14 이상 (`platforms: [.macOS(.v14)]`)
- Xcode 불필요: Command Line Tools + SwiftPM만 사용
- 외부 라이브러리 0개
- 인식: `ko-KR`, `requiresOnDeviceRecognition = true` 필수. 서버 인식으로 넘어가면 안 된다
- **Enter 자동 입력 금지.** 붙여넣는 텍스트는 앞뒤 공백·줄바꿈을 잘라 터미널에서 실행되지 않게 한다
- 붙여넣기는 클립보드 + ⌘V. 한 글자씩 키 입력 흉내 금지 (한글 IME 충돌)
- 화면 이름 `Voice Typing`, 코드·파일 이름 `VoiceTyping`, 번들 ID `local.voicetyping.VoiceTyping`
- 화면 문구·주석은 한국어
- 전역 단축키, 치환 사전, Whisper 엔진은 이번 범위가 아님
- 이 폴더는 git 저장소가 아니므로 커밋 단계는 없다 (보스 요청 시 `git init`)

## Review Focus

1. **말없이 정지** → 텍스트가 그대로이고 공백이 붙지 않아야 한다 (Task 1 `stopWithoutSpeech`)
2. **끝에 줄바꿈이 있는 텍스트를 붙여넣기** → 줄바꿈이 Enter로 처리되면 지시가 바로 실행된다. 앞뒤를 잘라야 한다 (Task 1 `outgoingTrims`)
3. **직접 고친 텍스트 뒤에 다시 녹음** → 고친 내용이 남고 뒤에 이어 붙어야 한다 (Task 1 `appendAfterEdit`)
4. **붙여넣을 앱이 없거나 손쉬운 사용 권한이 없음** → 복사만 하고 이유를 보여 주며 창을 열어 둔다 (Task 2 `blockedWithoutTarget`, `blockedWithoutPermission`)
5. **공백만 있는 텍스트** → 복사 버튼이 비활성이어야 한다 (Task 1 `whitespaceIsEmpty`)

---

## 파일 구조

```
voice-typing/
├── Package.swift
├── Sources/VoiceTyping/
│   ├── VoiceTypingApp.swift     # MenuBarExtra, PopoverView, RecordButton, LevelBars
│   ├── Transcriber.swift        # TranscriptBuffer(순수 로직) + Transcriber(마이크·인식)
│   └── Paster.swift             # 직전 앱 추적, 클립보드 복사, ⌘V 전송
├── Tests/VoiceTypingTests/
│   ├── TranscriptBufferTests.swift
│   ├── PasterTests.swift
│   └── TranscriberTests.swift
├── Resources/Info.plist
└── scripts/build-app.sh
```

---

### Task 1: 패키지 골격 + TranscriptBuffer

**Files:**
- Create: `Package.swift`
- Create: `Sources/VoiceTyping/VoiceTypingApp.swift` (빌드용 임시 골격, Task 4에서 교체)
- Create: `Sources/VoiceTyping/Transcriber.swift`
- Test: `Tests/VoiceTypingTests/TranscriptBufferTests.swift`

**Interfaces:**
- Produces: `struct TranscriptBuffer: Equatable` — `var text: String`, `private(set) var partial: String`, `var display: String`, `var outgoing: String`, `var isEmpty: Bool`, `mutating func update(_ recognized: String, utteranceEnded: Bool)`, `mutating func endSession()`, `mutating func clear()`, `static func join(_ head: String, _ tail: String) -> String`

- [ ] **Step 1: 패키지와 빌드용 골격 작성**

`Package.swift`:
```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VoiceTyping",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "VoiceTyping"),
        .testTarget(name: "VoiceTypingTests", dependencies: ["VoiceTyping"]),
    ],
    // AVAudioEngine·Speech 콜백이 Swift 6 엄격한 동시성 검사와 맞지 않아 Swift 5 모드로 빌드한다
    swiftLanguageModes: [.v5]
)
```

`Sources/VoiceTyping/VoiceTypingApp.swift` (임시):
```swift
import SwiftUI

@main
struct VoiceTypingApp: App {
    var body: some Scene {
        MenuBarExtra("Voice Typing", systemImage: "mic") { Text("준비 중") }
    }
}
```

`Sources/VoiceTyping/Transcriber.swift` (빈 파일로 시작): `import Foundation`

- [ ] **Step 2: 실패하는 테스트 작성** — `Tests/VoiceTypingTests/TranscriptBufferTests.swift`

```swift
import Testing
@testable import VoiceTyping

struct TranscriptBufferTests {
    @Test("부분 결과는 미확정 영역에만 반영된다")
    func partialResult() {
        var buffer = TranscriptBuffer()
        buffer.update("로그인", utteranceEnded: false)
        buffer.update("로그인 API", utteranceEnded: false)
        #expect(buffer.text == "")
        #expect(buffer.partial == "로그인 API")
        #expect(buffer.display == "로그인 API")
    }

    @Test("발화가 끝나면 확정된다")
    func utteranceEnd() {
        var buffer = TranscriptBuffer()
        buffer.update("로그인 API 확인해줘.", utteranceEnded: true)
        #expect(buffer.text == "로그인 API 확인해줘.")
        #expect(buffer.partial == "")
    }

    @Test("인식기가 결과를 새로 시작해도 앞 문장이 남는다")
    func recognizerResets() {
        var buffer = TranscriptBuffer()
        buffer.update("첫 문장.", utteranceEnded: true)
        buffer.update("둘째", utteranceEnded: false)
        #expect(buffer.display == "첫 문장. 둘째")
        buffer.update("둘째 문장.", utteranceEnded: true)
        #expect(buffer.text == "첫 문장. 둘째 문장.")
    }

    @Test("인식기가 앞 문장을 다시 붙여 보내도 중복되지 않는다")
    func recognizerAccumulates() {
        var buffer = TranscriptBuffer()
        buffer.update("첫 문장.", utteranceEnded: true)
        buffer.update("첫 문장. 둘째", utteranceEnded: false)
        #expect(buffer.display == "첫 문장. 둘째")
        buffer.update("첫 문장. 둘째 문장.", utteranceEnded: true)
        #expect(buffer.text == "첫 문장. 둘째 문장.")
    }

    @Test("정지하면 화면에 보이던 미확정 텍스트가 확정된다")
    func stopCommitsPartial() {
        var buffer = TranscriptBuffer()
        buffer.update("테스트 통과하면", utteranceEnded: false)
        buffer.endSession()
        #expect(buffer.text == "테스트 통과하면")
        #expect(buffer.partial == "")
    }

    @Test("말없이 정지해도 텍스트가 바뀌지 않는다")
    func stopWithoutSpeech() {
        var buffer = TranscriptBuffer()
        buffer.text = "기존 문장"
        buffer.endSession()
        #expect(buffer.text == "기존 문장")
    }

    @Test("직접 고친 텍스트 뒤에 이어서 쓴다")
    func appendAfterEdit() {
        var buffer = TranscriptBuffer()
        buffer.text = "직접 고친 문장"
        buffer.update("추가 문장", utteranceEnded: true)
        #expect(buffer.text == "직접 고친 문장 추가 문장")
    }

    @Test("공백이나 줄바꿈으로 끝나면 공백을 더하지 않는다")
    func noDoubleSpace() {
        var buffer = TranscriptBuffer()
        buffer.text = "첫 줄\n"
        buffer.update("둘째 줄", utteranceEnded: true)
        #expect(buffer.text == "첫 줄\n둘째 줄")
    }

    @Test("다음 녹음에서는 같은 말을 다시 해도 지우지 않는다")
    func newSessionKeepsRepeat() {
        var buffer = TranscriptBuffer()
        buffer.update("테스트", utteranceEnded: true)
        buffer.endSession()
        buffer.update("테스트", utteranceEnded: true)
        #expect(buffer.text == "테스트 테스트")
    }

    @Test("보낼 텍스트는 앞뒤 공백과 줄바꿈을 자른다 (Enter 로 실행되지 않게)")
    func outgoingTrims() {
        var buffer = TranscriptBuffer()
        buffer.text = "  commit 해줘\n\n"
        #expect(buffer.outgoing == "commit 해줘")
    }

    @Test("공백만 있으면 비어 있는 것으로 본다")
    func whitespaceIsEmpty() {
        var buffer = TranscriptBuffer()
        buffer.text = " \n "
        #expect(buffer.isEmpty)
    }

    @Test("지우기는 모두 비운다")
    func clearAll() {
        var buffer = TranscriptBuffer()
        buffer.update("첫 문장.", utteranceEnded: true)
        buffer.update("둘째", utteranceEnded: false)
        buffer.clear()
        #expect(buffer == TranscriptBuffer())
    }
}
```

- [ ] **Step 3: 실패 확인** — Run: `swift test` / Expected: 컴파일 실패 `cannot find 'TranscriptBuffer' in scope`

- [ ] **Step 4: 최소 구현** — `Sources/VoiceTyping/Transcriber.swift`

```swift
import Foundation

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
```

- [ ] **Step 5: 통과 확인** — Run: `swift test` / Expected: 12개 테스트 통과

---

### Task 2: Paster (클립보드 + 직전 앱 ⌘V)

**Files:**
- Create: `Sources/VoiceTyping/Paster.swift`
- Test: `Tests/VoiceTypingTests/PasterTests.swift`

**Interfaces:**
- Produces: `@Observable final class Paster` — `private(set) var target: NSRunningApplication?`, `init(center: NotificationCenter = NSWorkspace.shared.notificationCenter)`, `static func copy(_ text: String, to pasteboard: NSPasteboard = .general)`, `static func blocker(target: NSRunningApplication?, trusted: Bool) -> String?`, `func copyAndPaste(_ text: String) -> String?` (붙여넣었으면 nil, 못 했으면 이유)

- [ ] **Step 1: 실패하는 테스트 작성** — `Tests/VoiceTypingTests/PasterTests.swift`

```swift
import AppKit
import Testing
@testable import VoiceTyping

struct PasterTests {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("VoiceTypingTests-\(UUID().uuidString)"))
    let ownPID = ProcessInfo.processInfo.processIdentifier

    /// 테스트 프로세스가 아닌, 실행 중인 다른 앱 하나 (Finder 등)
    func otherApp() throws -> NSRunningApplication {
        try #require(NSWorkspace.shared.runningApplications.first { $0.processIdentifier != ownPID })
    }

    @Test("복사하면 클립보드에 텍스트가 들어간다")
    func copyWrites() {
        defer { pasteboard.releaseGlobally() }
        Paster.copy("commit 해줘", to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "commit 해줘")
    }

    @Test("복사는 클립보드의 기존 내용을 바꾼다")
    func copyReplaces() {
        defer { pasteboard.releaseGlobally() }
        Paster.copy("이전 내용", to: pasteboard)
        Paster.copy("새 내용", to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "새 내용")
    }

    @Test("Voice Typing 자신이 활성화되면 붙여넣기 대상으로 기억하지 않는다")
    func ignoresSelf() {
        let center = NotificationCenter()
        let paster = Paster(center: center)
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
                    userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
        #expect(paster.target?.processIdentifier != ownPID)
    }

    @Test("다른 앱이 활성화되면 붙여넣기 대상으로 기억한다")
    func remembersOtherApp() throws {
        let other = try otherApp()
        let center = NotificationCenter()
        let paster = Paster(center: center)
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
                    userInfo: [NSWorkspace.applicationUserInfoKey: other])
        #expect(paster.target?.processIdentifier == other.processIdentifier)
    }

    @Test("붙여넣을 앱이 없으면 복사만 한다")
    func blockedWithoutTarget() {
        #expect(Paster.blocker(target: nil, trusted: true) == "붙여넣을 앱이 없어 복사만 했습니다")
    }

    @Test("손쉬운 사용 권한이 없으면 복사만 한다")
    func blockedWithoutPermission() throws {
        let reason = Paster.blocker(target: try otherApp(), trusted: false)
        #expect(reason?.contains("손쉬운 사용") == true)
    }

    @Test("대상 앱과 권한이 있으면 붙여넣는다")
    func pasteAllowed() throws {
        #expect(Paster.blocker(target: try otherApp(), trusted: true) == nil)
    }
}
```

- [ ] **Step 2: 실패 확인** — Run: `swift test` / Expected: 컴파일 실패 `cannot find 'Paster' in scope`

- [ ] **Step 3: 최소 구현** — `Sources/VoiceTyping/Paster.swift`

```swift
import AppKit
import ApplicationServices
import Observation

/// 클립보드 복사와, 직전에 쓰던 앱에 ⌘V 를 보내는 일을 맡는다.
@Observable
final class Paster {
    /// 붙여넣을 대상 — Voice Typing 자신이 아닌, 마지막으로 활성화된 앱
    private(set) var target: NSRunningApplication?

    @ObservationIgnored private let center: NotificationCenter
    @ObservationIgnored private var observer: NSObjectProtocol?

    /// - Parameter center: 앱 활성화 알림을 받을 곳. 테스트에서는 별도 인스턴스를 넣는다.
    init(center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.center = center
        // 팝오버를 열면 Voice Typing 자신이 활성 앱이 되므로, 그 전에 쓰던 앱을 계속 기록해 둔다
        remember(NSWorkspace.shared.frontmostApplication)
        observer = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                      object: nil, queue: nil) { [weak self] note in
            self?.remember(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
    }

    deinit {
        if let observer { center.removeObserver(observer) }
    }

    private func remember(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        target = app
    }

    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// ⌘V 를 보낼 수 없는 이유. 보낼 수 있으면 nil.
    static func blocker(target: NSRunningApplication?, trusted: Bool) -> String? {
        guard let target, !target.isTerminated else { return "붙여넣을 앱이 없어 복사만 했습니다" }
        guard trusted else { return "손쉬운 사용 권한이 없어 복사만 했습니다 — ⌘V를 눌러 주세요" }
        return nil
    }

    /// 클립보드에 복사하고 대상 앱에 ⌘V 를 보낸다. 붙여넣지 못했으면 그 이유를 돌려준다.
    func copyAndPaste(_ text: String) -> String? {
        Self.copy(text)
        // 권한이 없으면 시스템이 '손쉬운 사용' 허용 안내 창을 띄운다
        let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if let reason = Self.blocker(target: target, trusted: trusted) { return reason }
        target?.activate()
        // ponytail: 대상 앱이 앞으로 나올 시간을 고정 150ms 로 둔다. 늦게 뜨는 앱이 있으면 이 값만 늘린다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let source = CGEventSource(stateID: .combinedSessionState)
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: keyDown)  // 9 = V 키
                event?.flags = .maskCommand
                event?.post(tap: .cghidEventTap)
            }
        }
        return nil
    }
}
```

- [ ] **Step 4: 통과 확인** — Run: `swift test` / Expected: 19개 테스트 통과 (Task 1 12개 + 7개)

---

### Task 3: Transcriber (마이크 + 온디바이스 인식)

**Files:**
- Modify: `Sources/VoiceTyping/Transcriber.swift` (import 추가, 파일 끝에 `Transcriber` 추가)
- Test: `Tests/VoiceTypingTests/TranscriberTests.swift`

**Interfaces:**
- Consumes: `TranscriptBuffer` (Task 1)
- Produces: `@Observable final class Transcriber` — `var buffer: TranscriptBuffer`, `private(set) var state: State` (`.idle`, `.recording`, `.failed(String, settings: URL?)`), `private(set) var startedAt: Date`, `private(set) var levels: [Float]`, `var isRecording: Bool`, `func toggle()`, `func stop()`, `static let vocabulary: [String]`, `static func makeRequest() -> SFSpeechAudioBufferRecognitionRequest`, `static func level(of pcm: AVAudioPCMBuffer) -> Float`

- [ ] **Step 1: 실패하는 테스트 작성** — `Tests/VoiceTypingTests/TranscriberTests.swift`

```swift
import AVFoundation
import Testing
@testable import VoiceTyping

struct TranscriberTests {
    /// 진폭이 일정한 1채널 소리 버퍼
    func pcm(amplitude: Float) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        let samples = try #require(buffer.floatChannelData?[0])
        for i in 0..<480 { samples[i] = i.isMultiple(of: 2) ? amplitude : -amplitude }
        return buffer
    }

    @Test("인식 요청은 외부 전송 없이 Mac 안에서만 처리한다")
    func onDeviceOnly() {
        let request = Transcriber.makeRequest()
        #expect(request.requiresOnDeviceRecognition)
        #expect(request.shouldReportPartialResults)
        #expect(request.addsPunctuation)
        #expect(request.contextualStrings == Transcriber.vocabulary)
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
}
```

- [ ] **Step 2: 실패 확인** — Run: `swift test` / Expected: 컴파일 실패 `cannot find 'Transcriber' in scope`

- [ ] **Step 3: 구현** — `Transcriber.swift` 첫 줄 `import Foundation`을 아래로 바꾸고, 파일 끝에 `Transcriber`를 추가

```swift
import AVFoundation
import Observation
import Speech
import os
```

```swift
/// 마이크 소리를 온디바이스 한국어 인식기로 넘기고, 결과를 TranscriptBuffer 에 모은다.
@Observable
final class Transcriber {
    enum State: Equatable {
        case idle
        case recording
        /// 녹음을 시작하지 못함. settings 가 있으면 시스템 설정의 해당 화면을 열 수 있다.
        case failed(String, settings: URL?)
    }

    /// 인식 정확도를 높이려고 미리 알려 주는 영어 용어
    // ponytail: 고정 목록. 자주 틀리는 단어가 보이면 여기에 추가한다 (Apple 권장 최대 100개).
    static let vocabulary = [
        "Claude Code", "Claude", "commit", "push", "pull request", "PR", "merge", "branch",
        "API", "README", "test", "build", "deploy", "TypeScript", "Swift", "Python", "JSON",
    ]

    var buffer = TranscriptBuffer()
    private(set) var state = State.idle
    private(set) var startedAt = Date()
    /// 최근 마이크 음량 (0...1). 녹음 중 파형 막대로 보여 준다.
    private(set) var levels = [Float](repeating: 0, count: 24)

    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ko-KR"))
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var session = 0       // 정지한 뒤 늦게 도착한 콜백을 버리는 데 쓴다
    @ObservationIgnored private var starting = false  // 권한 확인 중 버튼을 또 눌러도 두 번 시작하지 않게
    // 진단용: 인식 결과의 길이·신호만 남기고 내용은 남기지 않는다
    // 확인: log stream --level debug --predicate 'subsystem == "local.voicetyping"'
    private static let log = Logger(subsystem: "local.voicetyping", category: "speech")

    var isRecording: Bool { state == .recording }

    func toggle() {
        if isRecording { stop(); return }
        guard !starting else { return }
        starting = true
        Task { @MainActor in
            await start()
            starting = false
        }
    }

    static func makeRequest() -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true   // 외부 전송 차단: 서버 인식으로 넘어가지 않는다
        request.shouldReportPartialResults = true    // 말하는 동안 실시간으로 보여 준다
        request.addsPunctuation = true
        request.contextualStrings = vocabulary
        return request
    }

    @MainActor
    private func start() async {
        if let settings = await Self.missingPermission() {
            state = .failed("마이크·음성 인식 권한이 필요합니다", settings: settings)
            return
        }
        guard let recognizer, recognizer.supportsOnDeviceRecognition else {
            state = .failed("이 Mac에서는 한국어 온디바이스 인식을 쓸 수 없습니다", settings: nil)
            return
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            state = .failed("마이크를 찾을 수 없습니다", settings: nil)
            return
        }

        let request = Self.makeRequest()
        session += 1
        let current = session
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] pcm, _ in
            request.append(pcm)
            let level = Self.level(of: pcm)
            DispatchQueue.main.async { self?.push(level, session: current) }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            state = .failed("마이크를 시작하지 못했습니다: \(error.localizedDescription)", settings: nil)
            return
        }
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.session == current else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    let ended = result.isFinal || result.speechRecognitionMetadata != nil
                    Self.log.debug("결과 final=\(result.isFinal) meta=\(result.speechRecognitionMetadata != nil) len=\(text.count)")
                    self.buffer.update(text, utteranceEnded: ended)
                }
                if let error { Self.log.error("인식 종료: \(error.localizedDescription, privacy: .public)") }
                // ponytail: 인식기가 스스로 끝나면(오류·긴 침묵) 녹음도 멈춘다. 자주 끊기면 자동 재시작을 넣는다.
                if result?.isFinal == true || error != nil { self.stop() }
            }
        }
        startedAt = Date()
        state = .recording
    }

    func stop() {
        guard isRecording else { return }
        session += 1
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        task?.cancel()
        task = nil
        buffer.endSession()
        levels = [Float](repeating: 0, count: levels.count)
        state = .idle
    }

    private func push(_ level: Float, session current: Int) {
        guard session == current else { return }
        levels.removeFirst()
        levels.append(level)
    }

    /// 권한을 요청한다. 거부된 권한이 있으면 시스템 설정의 해당 화면 주소를 돌려준다.
    private static func missingPermission() async -> URL? {
        let base = "x-apple.systempreferences:com.apple.preference.security?"
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        if speech != .authorized { return URL(string: base + "Privacy_SpeechRecognition") }
        if await !AVCaptureDevice.requestAccess(for: .audio) { return URL(string: base + "Privacy_Microphone") }
        return nil
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
```

- [ ] **Step 4: 통과 확인** — Run: `swift test` / Expected: 23개 테스트 통과

---

### Task 4: 메뉴바 화면 + .app 번들

**Files:**
- Modify: `Sources/VoiceTyping/VoiceTypingApp.swift` (임시 골격 전체 교체)
- Create: `Resources/Info.plist`
- Create: `scripts/build-app.sh`

**Interfaces:**
- Consumes: `Transcriber` (Task 3), `Paster` (Task 2), `TranscriptBuffer` (Task 1)

화면·권한·키 이벤트는 단위 테스트가 어려워 빌드 + 실행 확인 + Task 5 수동 QA로 검증한다.

- [ ] **Step 1: 화면 구현** — `Sources/VoiceTyping/VoiceTypingApp.swift`

```swift
import AppKit
import SwiftUI

@main
struct VoiceTypingApp: App {
    @State private var transcriber = Transcriber()
    @State private var paster = Paster()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(transcriber: transcriber, paster: paster)
        } label: {
            Image(nsImage: Self.icon(recording: transcriber.isRecording))
        }
        .menuBarExtraStyle(.window)
    }

    /// 평소에는 메뉴바 색을 따르는 마이크, 녹음 중에는 빨간 마이크
    static func icon(recording: Bool) -> NSImage {
        let base = NSImage(systemSymbolName: recording ? "mic.fill" : "mic", accessibilityDescription: "Voice Typing")!
        guard recording, let red = base.withSymbolConfiguration(.init(paletteColors: [.systemRed])) else { return base }
        red.isTemplate = false
        return red
    }
}

struct PopoverView: View {
    @Bindable var transcriber: Transcriber
    let paster: Paster
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            status
            textArea
            actions
            footer
        }
        .padding(14)
        .frame(width: 360)
    }

    private var header: some View {
        HStack {
            Text("Voice Typing").font(.headline)
            Spacer()
            Text("🔒 한국어 · 온디바이스")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .overlay(Capsule().stroke(.quaternary))
        }
    }

    @ViewBuilder private var status: some View {
        switch transcriber.state {
        case .recording:
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("녹음 중").fontWeight(.semibold)
                Text(transcriber.startedAt, style: .timer).monospacedDigit()
                Spacer()
                LevelBars(levels: transcriber.levels)
            }
            .foregroundStyle(.red)
            .font(.callout)
        case .failed(let message, let settings):
            VStack(alignment: .leading, spacing: 6) {
                Text("⚠️ \(message)")
                if let settings {
                    Button("시스템 설정 열기") { NSWorkspace.shared.open(settings) }
                }
            }
            .font(.callout)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        case .idle:
            Text(transcriber.buffer.isEmpty ? "녹음 버튼을 누르고 말씀하세요" : "✓ 인식 완료 · 필요하면 직접 수정하세요")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var textArea: some View {
        Group {
            if transcriber.isRecording {
                ScrollViewReader { proxy in
                    ScrollView {
                        liveText
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(5)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .onChange(of: transcriber.buffer.display) { proxy.scrollTo("end") }
                }
            } else {
                TextEditor(text: $transcriber.buffer.text)
                    .scrollContentBackground(.hidden)
                    .overlay(alignment: .topLeading) {
                        if transcriber.buffer.text.isEmpty {
                            Text("여기에 인식된 텍스트가 표시됩니다. 직접 고칠 수도 있습니다.")
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
            }
        }
        .font(.system(size: 15))
        .frame(height: 140)
        .padding(4)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }

    /// 확정된 글자는 기본색, 아직 바뀔 수 있는 글자는 회색
    private var liveText: Text {
        let buffer = transcriber.buffer
        let tail = String(buffer.display.dropFirst(buffer.text.count))
        return Text(buffer.text) + Text(tail).foregroundColor(.secondary)
    }

    private var actions: some View {
        let disabled = transcriber.buffer.isEmpty || transcriber.isRecording
        return HStack(spacing: 8) {
            RecordButton(recording: transcriber.isRecording) {
                notice = nil
                transcriber.toggle()
            }
            Spacer()
            Button { transcriber.buffer.clear(); notice = nil } label: { Image(systemName: "trash") }
                .help("지우기")
                .disabled(disabled)
            Button("복사") {
                Paster.copy(transcriber.buffer.outgoing)
                notice = "클립보드에 복사했습니다"
            }
            .disabled(disabled)
            Button("복사+붙여넣기") { copyAndPaste() }
                .buttonStyle(.borderedProminent)
                .disabled(disabled)
        }
    }

    private var footer: some View {
        HStack {
            if let notice {
                Text(notice).foregroundStyle(.tint)
            } else {
                Text("붙여넣기 대상: \(paster.target?.localizedName ?? "없음") · Enter는 직접 누르세요")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("종료") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
        }
        .font(.caption)
    }

    private func copyAndPaste() {
        if let reason = paster.copyAndPaste(transcriber.buffer.outgoing) {
            notice = reason          // 붙여넣지 못했으면 창을 열어 둔 채 이유를 보여 준다
            return
        }
        transcriber.buffer.clear()
        notice = nil
        NSApp.keyWindow?.close()     // 팝오버를 닫는다. 대상 앱은 Paster 가 앞으로 가져온다
    }
}

/// 빨간 원형 녹음 버튼. 녹음 중에는 가운데가 사각형(정지)으로 바뀐다.
struct RecordButton: View {
    let recording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(.red).frame(width: 44, height: 44)
                if recording {
                    RoundedRectangle(cornerRadius: 3).fill(.white).frame(width: 14, height: 14)
                } else {
                    Circle().fill(.white).frame(width: 16, height: 16)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(recording ? "녹음 정지" : "녹음 시작")
    }
}

/// 최근 마이크 음량을 막대로 보여 준다
struct LevelBars: View {
    let levels: [Float]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(.red.opacity(0.85))
                    .frame(width: 3, height: 3 + CGFloat(levels[i]) * 17)
            }
        }
        .frame(height: 22)
    }
}
```

- [ ] **Step 2: Info.plist** — `Resources/Info.plist`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>local.voicetyping.VoiceTyping</string>
    <key>CFBundleName</key>
    <string>VoiceTyping</string>
    <key>CFBundleDisplayName</key>
    <string>Voice Typing</string>
    <key>CFBundleExecutable</key>
    <string>VoiceTyping</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>말씀하신 내용을 텍스트로 바꾸려고 마이크를 사용합니다. 소리는 Mac 밖으로 나가지 않습니다.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>음성을 Mac 안에서(온디바이스) 텍스트로 바꿉니다. 외부로 전송하지 않습니다.</string>
</dict>
</plist>
```

- [ ] **Step 3: 빌드 스크립트** — `scripts/build-app.sh` (실행 권한 부여)

```bash
#!/bin/bash
# swift build 결과를 VoiceTyping.app 번들로 묶고 서명한다.
# 사용: scripts/build-app.sh          빌드만
#       scripts/build-app.sh --open   빌드 후 실행 (이미 실행 중이면 종료하고 다시 실행)
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP=build/VoiceTyping.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/VoiceTyping "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
# 자체 서명 인증서 이름을 VOICETYPING_SIGN_ID 로 주면 재빌드해도 손쉬운 사용 권한이 유지된다. 없으면 임시(ad-hoc) 서명.
codesign --force --sign "${VOICETYPING_SIGN_ID:--}" "$APP"
echo "빌드 완료: $APP"

if [[ "${1:-}" == "--open" ]]; then
    pkill -x VoiceTyping || true
    open "$APP"
fi
```

- [ ] **Step 4: 확인** — Run: `swift test && plutil -lint Resources/Info.plist && scripts/build-app.sh --open && sleep 2 && pgrep -x VoiceTyping`
Expected: 23개 테스트 통과, plist OK, `빌드 완료`, 프로세스 ID 출력 (메뉴바에 🎙 아이콘)

---

### Task 5: 수동 QA (보스와 함께)

마이크, 권한 팝업, 다른 앱으로의 키 입력은 자동 테스트가 어렵다. 아래를 실제로 써 보며 확인한다.

- [ ] 첫 녹음 시 음성 인식 → 마이크 권한 요청이 차례로 뜬다
- [ ] 권한을 거부하면 "시스템 설정 열기" 안내가 나온다
- [ ] 말하는 동안 글자가 실시간으로 나오고, 확정 전 글자는 회색이다
- [ ] 문장 사이에 2초쯤 쉬어도 앞 문장이 사라지거나 두 번 나오지 않는다 (`log stream --level debug --predicate 'subsystem == "local.voicetyping"'`로 신호 확인)
- [ ] Wi-Fi를 끈 상태에서 인식된다
- [ ] 1분 이상 연속으로 말해도 끊기지 않는다
- [ ] 터미널에서 [복사+붙여넣기]가 Claude Code 입력창에 들어가고, Enter는 눌리지 않는다
- [ ] 손쉬운 사용 권한이 없으면 복사까지만 하고 안내가 나온다
- [ ] [종료]로 앱이 끝난다

---

## 구현 결과 (2026-10-06)

| 항목 | 결과 |
|---|---|
| 단위 테스트 | `swift test` **35개 통과**, 경고 0 (TranscriptBuffer 12, Paster 11, Transcriber 10, AppVersion 2) |
| 빌드 | `./build.sh` → `build/Voice Typing.app` + `dist/VoiceTyping-<버전>.dmg` (임시 서명). `scripts/build-app.sh` 를 대체 |
| 설치 | `./install.sh` → dmg 를 Finder 창 없이 마운트해 `/Applications/Voice Typing.app` 에 설치하고 뒤에서 실행 (v1.0.0 설치 확인) |
| 아이콘 | C안(말풍선 "가A") 선택 → `Resources/AppIcon.icns`, 원본 `docs/assets/icons/icon-c-bubble-hangul.svg` |
| 버전 | `VERSION` 파일이 기준. `./build.sh` 가 번들의 `CFBundleShortVersionString`·`CFBundleVersion` 에 넣고, 팝오버 제목 옆에 `v1.0.0` 표시 |
| 최종 리뷰 | 새 리뷰어 1회. Critical 0, Important 4건 모두 테스트 먼저 작성 후 수정 |

### 리뷰 후 계획에서 바뀐 점

- **정지 동작:** 바로 끊지 않고 마이크를 끈 뒤 인식기의 최종 결과를 최대 1.5초 기다린다 (`State.finishing`, 화면에 "마무리 중…"). 마지막 단어가 빠지지 않게 하기 위함이다.
- **인식 콜백 처리:** `Transcriber.steps(...)` 순수 함수로 분리해 테스트한다. 녹음 중 오류는 화면에 이유를 보여 준다.
- **붙여넣기:** `copyAndPaste`가 `async`가 되었다. 대상 앱이 실제로 앞에 온 것을 확인한 뒤(최대 1초)에만 ⌘V를 보내고, 실패하면 텍스트를 지우지 않는다.
- **붙여넣기 대상:** 일반 앱(`activationPolicy == .regular`)만 기억한다. 손쉬운 사용 허용 안내 창은 실행 중 한 번만 띄운다.
- **빌드 스크립트:** 실행 중인 앱을 끝낸 뒤 완전히 종료될 때까지 기다렸다가 다시 연다.

### 남은 확인 (보스 QA, Task 5)

위 Task 5 체크리스트에 더해, 리뷰에서 실기기로만 알 수 있다고 한 항목:
- 녹음 중 메뉴바 아이콘이 빨갛게 보이는지
- 문장 사이에 쉬었을 때 중복이나 누락이 없는지 (`log stream --level debug --predicate 'subsystem == "local.voicetyping"'`)
- 텍스트를 직접 고치다가(한글 조합 중) 바로 버튼을 눌러도 마지막 글자가 반영되는지
