import AppKit
import SwiftUI
import Testing
@testable import VoiceTyping

/// README 의 앱 화면 이미지를 실제 화면 코드(PopoverView)로 그린다.
/// 창을 화면에 띄우지 않으므로 사용자의 화면·포커스를 건드리지 않는다. 화면을 고친 뒤 다시 실행하면 이미지도 갱신된다.
/// 실행: README_SCREENSHOTS_DIR=docs/assets/readme VOICETYPING_MODEL_BASE="$HOME/Library/Application Support/VoiceTyping" \
///       swift test --filter ReadmeScreenshots
private let env = ProcessInfo.processInfo.environment

@MainActor
struct ReadmeScreenshots {
    @Test("README 앱 화면 이미지 3장을 만든다",
          .enabled(if: env["README_SCREENSHOTS_DIR"] != nil && env["VOICETYPING_MODEL_BASE"] != nil))
    func render() async throws {
        let out = URL(fileURLWithPath: try #require(env["README_SCREENSHOTS_DIR"]))
        let version = "v" + (try String(contentsOfFile: "VERSION", encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)

        // 붙여넣기 대상: 실행 중인 터미널 앱
        let center = NotificationCenter()
        let paster = Paster(center: center)
        let terminals = ["com.apple.Terminal"]
        if let terminal = NSWorkspace.shared.runningApplications.first(where: { terminals.contains($0.bundleIdentifier ?? "") }) {
            center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
                        userInfo: [NSWorkspace.applicationUserInfoKey: terminal])
        }

        // ① 첫 실행: 모델이 없어 내려받기 버튼이 보이는 화면
        let fresh = SpeechModel(base: FileManager.default.temporaryDirectory.appending(path: "voicetyping-\(UUID().uuidString)"))
        await fresh.prepare()
        try await snapshot(PopoverView(transcriber: Transcriber(model: fresh), model: fresh, paster: paster, version: version),
                           to: out.appending(path: "01-model-download.png"))

        // ② 녹음 중: 받아쓴 글자가 회색(아직 바뀔 수 있음)으로 따라오는 화면
        let model = SpeechModel(base: URL(fileURLWithPath: try #require(env["VOICETYPING_MODEL_BASE"])))
        await model.prepare()
        try #require(model.state == .ready)
        let recording = Transcriber(model: model)
        recording.buffer.update("오늘 Claude Code에서 commit하고 push한 다음에", utteranceEnded: false)
        let levels: [Float] = [0.05, 0.1, 0.3, 0.55, 0.4, 0.7, 0.5, 0.25, 0.6, 0.8, 0.45, 0.3,
                               0.5, 0.65, 0.35, 0.2, 0.45, 0.7, 0.55, 0.3, 0.15, 0.4, 0.6, 0.35]
        recording.showRecordingForScreenshot(levels: levels, startedAt: Date().addingTimeInterval(-6))
        try await snapshot(PopoverView(transcriber: recording, model: model, paster: paster, version: version),
                           to: out.appending(path: "02-recording.png"))

        // ③ 인식 완료: 확정된 글자를 고치거나 복사+붙여넣기 하는 화면
        let done = Transcriber(model: model)
        done.buffer.text = "오늘 Claude Code에서 commit하고 push한 다음에 pull request 만들어줘."
        try await snapshot(PopoverView(transcriber: done, model: model, paster: paster, version: version),
                           to: out.appending(path: "03-done.png"))
    }

    /// 화면에 띄우지 않은 창에서 2배 해상도 PNG 로 그린다 (다크 모드, 메뉴바 창처럼 둥근 모서리)
    func snapshot(_ view: PopoverView, to url: URL) async throws {
        let root = view
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        try await Task.sleep(for: .milliseconds(300))   // SwiftUI 가 그릴 시간을 준다
        host.layoutSubtreeIfNeeded()

        let scale = 2
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width) * scale, pixelsHigh: Int(host.bounds.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}
