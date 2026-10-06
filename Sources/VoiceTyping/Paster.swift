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

    /// Dock 에 나오는 일반 앱만 기억한다. 권한 대화상자 같은 시스템 보조 프로세스가 대상을 가로채지 않게 한다.
    private func remember(_ app: NSRunningApplication?) {
        guard let app, app.activationPolicy == .regular,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        target = app
    }

    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static let needsAccessibility = "손쉬운 사용 권한이 없어 복사만 했습니다 — ⌘V를 눌러 주세요"
    static let accessibilitySettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    /// ⌘V 를 보낼 수 없는 이유. 보낼 수 있으면 nil.
    static func blocker(target: NSRunningApplication?, trusted: Bool) -> String? {
        guard let target, !target.isTerminated else { return "붙여넣을 앱이 없어 복사만 했습니다" }
        guard trusted else { return needsAccessibility }
        return nil
    }

    /// 클립보드에 복사하고, 대상 앱을 앞으로 가져와 ⌘V 를 보낸다. 붙여넣지 못했으면 그 이유를 돌려준다.
    @MainActor
    func copyAndPaste(_ text: String) async -> String? {
        Self.copy(text)
        if let reason = Self.blocker(target: target, trusted: Self.isTrusted()) { return reason }
        guard let target, target.activate() else {
            return "붙여넣을 앱을 앞으로 가져오지 못해 복사만 했습니다 — ⌘V를 눌러 주세요"
        }
        // 다른 Space 의 전체 화면 앱은 전환에 시간이 걸린다. 실제로 앞에 온 뒤에만 ⌘V 를 보낸다.
        let pid = target.processIdentifier
        guard await Self.wait(until: { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }) else {
            return "\(target.localizedName ?? "대상 앱")이(가) 앞으로 나오지 않아 복사만 했습니다 — ⌘V를 눌러 주세요"
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: keyDown)  // 9 = V 키
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
        return nil
    }

    /// 조건이 참이 될 때까지 50ms 간격으로 확인한다. 제한 시간 안에 참이 되면 true.
    static func wait(timeout: Duration = .seconds(1), until condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private static var prompted = false

    /// 손쉬운 사용 권한 확인. 실행 중 처음 한 번만 시스템 허용 안내 창을 띄운다 (매번 띄우면 팝오버가 닫힌다).
    static func isTrusted() -> Bool {
        defer { prompted = true }
        return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": !prompted] as CFDictionary)
    }
}

#if DEBUG
extension Paster {
    /// README 화면 캡처용: 붙여넣기 대상을 macOS 기본 터미널로 보이게 한다 (디버그 빌드 전용, 터미널이 실행 중이어야 함)
    /// 캡처 도중 다른 앱을 써도 대상이 바뀌지 않게 앱 전환 기록을 멈춘다.
    func stageForScreenshot() {
        if let observer { center.removeObserver(observer) }
        observer = nil
        target = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first
    }
}
#endif
