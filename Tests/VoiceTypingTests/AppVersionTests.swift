import Testing
@testable import VoiceTyping

struct AppVersionTests {
    @Test("앱 정보의 버전을 v 를 붙여 보여 준다")
    func labelFromBundle() {
        #expect(AppVersion.label(from: ["CFBundleShortVersionString": "1.0.0"]) == "v1.0.0")
    }

    @Test("앱 번들 없이 실행하면 버전을 표시하지 않는다")
    func labelWithoutBundle() {
        #expect(AppVersion.label(from: nil) == "")
        #expect(AppVersion.label(from: [:]) == "")
    }
}
