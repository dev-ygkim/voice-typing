import AppKit
import Testing
@testable import VoiceTyping

struct PasterTests {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("VoiceTypingTests-\(UUID().uuidString)"))
    let ownPID = ProcessInfo.processInfo.processIdentifier

    /// 테스트 프로세스가 아닌, 실행 중인 일반 앱 하나 (Finder 등)
    func otherApp() throws -> NSRunningApplication {
        try #require(NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular && $0.processIdentifier != ownPID
        })
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

    @Test("시스템 대화상자 같은 보조 프로세스는 붙여넣기 대상으로 기억하지 않는다")
    func ignoresBackgroundHelpers() throws {
        let helper = try #require(NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy != .regular && $0.processIdentifier != ownPID
        })
        let center = NotificationCenter()
        let paster = Paster(center: center)
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
                    userInfo: [NSWorkspace.applicationUserInfoKey: helper])
        #expect(paster.target?.processIdentifier != helper.processIdentifier)
    }

    @Test("대상 앱이 이미 앞에 있으면 바로 진행한다")
    func waitPassesImmediately() async {
        #expect(await Paster.wait(timeout: .milliseconds(200)) { true })
    }

    @Test("대상 앱이 늦게 앞으로 나와도 기다렸다가 진행한다")
    func waitPassesLater() async {
        var checks = 0
        #expect(await Paster.wait(timeout: .seconds(1)) { checks += 1; return checks >= 3 })
    }

    @Test("제한 시간 안에 대상 앱이 앞으로 나오지 않으면 ⌘V 를 보내지 않는다")
    func waitGivesUp() async {
        #expect(await Paster.wait(timeout: .milliseconds(200)) { false } == false)
    }
}
