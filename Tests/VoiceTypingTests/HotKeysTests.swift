import AppKit
import Foundation
import Testing
@testable import VoiceTyping

struct HotKeysTests {
    @Test("단축키는 ⌃⌥⇧⌘ 순서로 기호를 붙여 보여 준다")
    func display() throws {
        let shortcut = try #require(Shortcut(keyCode: 15, modifiers: [.command, .shift, .option, .control], characters: "r"))
        #expect(shortcut.display == "⌃⌥⇧⌘R")
        #expect(Shortcut(keyCode: 49, modifiers: [.control, .option], characters: " ")?.display == "⌃⌥Space")
        #expect(Shortcut(keyCode: 51, modifiers: [.control, .option], characters: "\u{7F}")?.display == "⌃⌥⌫")   // 지우기(delete) 키
    }

    @Test("⌃·⌥·⌘ 없이 누른 키는 단축키로 받지 않는다 (평소 타자를 가로채지 않게)")
    func rejectsPlainKeys() {
        #expect(Shortcut(keyCode: 15, modifiers: [], characters: "r") == nil)
        #expect(Shortcut(keyCode: 15, modifiers: [.shift], characters: "R") == nil)
    }

    @Test("기본 단축키는 녹음 시작 ⌃⌥R, 녹음 중지 ⌃⌥S, 복사 ⌃⌥C, 복사+붙여넣기 ⌃⌥V, 지우기 ⌃⌥D")
    func defaults() {
        #expect(HotKeyAction.allCases.map(\.defaultShortcut.display) == ["⌃⌥R", "⌃⌥S", "⌃⌥C", "⌃⌥V", "⌃⌥D"])
    }

    @Test("녹음 시작은 대기 중이고 모델이 준비됐을 때만, 중지는 녹음 중일 때만")
    func recordRules() {
        #expect(HotKeyAction.start.isAllowed(state: .idle, modelReady: true, hasText: false))
        #expect(!HotKeyAction.start.isAllowed(state: .idle, modelReady: false, hasText: false))
        #expect(!HotKeyAction.start.isAllowed(state: .finishing, modelReady: true, hasText: false))
        #expect(HotKeyAction.stop.isAllowed(state: .recording, modelReady: true, hasText: false))
        #expect(!HotKeyAction.stop.isAllowed(state: .idle, modelReady: true, hasText: false))
    }

    @Test("복사·붙여넣기·지우기는 글자가 있고 녹음·마무리 중이 아닐 때만 (메뉴바 창 버튼과 같음)")
    func copyRules() {
        for action in [HotKeyAction.copy, .paste, .clear] {
            #expect(action.isAllowed(state: .idle, modelReady: true, hasText: true))
            #expect(!action.isAllowed(state: .idle, modelReady: true, hasText: false))
            #expect(!action.isAllowed(state: .recording, modelReady: true, hasText: true))
            #expect(!action.isAllowed(state: .finishing, modelReady: true, hasText: true))
        }
    }

    @Test("시작과 중지에 같은 조합을 넣으면 한 키로 켜고 끈다")
    func sameKeyToggles() {
        #expect(HotKeyAction.pick([.start, .stop], state: .idle, modelReady: true, hasText: false) == .start)
        #expect(HotKeyAction.pick([.start, .stop], state: .recording, modelReady: true, hasText: false) == .stop)
        #expect(HotKeyAction.pick([.stop], state: .idle, modelReady: true, hasText: false) == nil)
    }

    @Test("저장한 단축키와 지운 단축키를 다시 켜도 그대로 불러온다. 한 번도 안 바꾼 것은 기본값")
    func storeRoundTrip() throws {
        let defaults = try #require(UserDefaults(suiteName: "voicetyping-test-\(UUID().uuidString)"))
        let store = ShortcutStore(defaults: defaults)
        let custom = try #require(Shortcut(keyCode: 49, modifiers: [.command, .shift], characters: " "))
        store.save(custom, for: .start)
        store.save(nil, for: .copy)

        let loaded = ShortcutStore(defaults: defaults).load()
        #expect(loaded[.start] == custom)
        #expect(loaded[.copy] == nil)
        #expect(loaded[.stop] == HotKeyAction.stop.defaultShortcut)
        #expect(loaded[.paste] == HotKeyAction.paste.defaultShortcut)
    }
}
