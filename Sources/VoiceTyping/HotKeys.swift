import AppKit
import Carbon.HIToolbox
import Observation

/// 단축키 하나: 키 + ⌃⌥⇧⌘
struct Shortcut: Codable, Hashable {
    let keyCode: UInt16
    /// NSEvent.ModifierFlags 중 ⌃⌥⇧⌘ 만
    let flags: UInt
    /// 화면에 보일 키 이름 (예: "R", "Space")
    let key: String

    private static let modifierMask: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
    /// 글자가 아닌 키의 이름
    private static let keyNames: [UInt16: String] = [
        UInt16(kVK_Space): "Space", UInt16(kVK_Return): "↩", UInt16(kVK_Tab): "⇥", UInt16(kVK_Delete): "⌫",
        UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→", UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓",
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3", UInt16(kVK_F4): "F4",
        UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6", UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8",
        UInt16(kVK_F9): "F9", UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
    ]

    /// 키 입력으로 단축키를 만든다. ⌃·⌥·⌘ 중 하나도 없으면 평소 타자를 가로채므로 nil.
    /// - Parameter characters: 수정키를 뺀 글자 (NSEvent.charactersIgnoringModifiers)
    init?(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String?) {
        let mods = modifiers.intersection(Self.modifierMask)
        guard !mods.intersection([.control, .option, .command]).isEmpty,
              let key = Self.keyNames[keyCode] ?? characters?.uppercased(), !key.isEmpty else { return nil }
        self.keyCode = keyCode
        self.flags = mods.rawValue
        self.key = key
    }

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: flags) }

    var display: String {
        [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { modifiers.contains($0.0) }.map(\.1).joined() + key
    }

    /// RegisterEventHotKey 가 받는 수정키 값
    var carbonModifiers: UInt32 {
        [(NSEvent.ModifierFlags.control, controlKey), (.option, optionKey), (.shift, shiftKey), (.command, cmdKey)]
            .filter { modifiers.contains($0.0) }.reduce(0) { $0 | UInt32($1.1) }
    }
}

/// 단축키로 할 수 있는 일
enum HotKeyAction: String, CaseIterable {
    case start, stop, copy, paste, clear

    var title: String {
        switch self {
        case .start: "녹음 시작"
        case .stop: "녹음 중지"
        case .copy: "복사"
        case .paste: "복사+붙여넣기"
        case .clear: "지우기"
        }
    }

    var defaultShortcut: Shortcut {
        let (code, letter) = switch self {
        case .start: (kVK_ANSI_R, "r")
        case .stop: (kVK_ANSI_S, "s")
        case .copy: (kVK_ANSI_C, "c")
        case .paste: (kVK_ANSI_V, "v")
        case .clear: (kVK_ANSI_D, "d")
        }
        return Shortcut(keyCode: UInt16(code), modifiers: [.control, .option], characters: letter)!
    }

    /// 지금 상태에서 이 일을 할 수 있는지. 메뉴바 창의 버튼이 켜지는 조건과 같다.
    func isAllowed(state: Transcriber.State, modelReady: Bool, hasText: Bool) -> Bool {
        let busy = state == .recording || state == .finishing
        return switch self {
        case .start: !busy && modelReady
        case .stop: state == .recording
        case .copy, .paste, .clear: hasText && !busy
        }
    }

    /// 한 조합에 묶인 일 중 지금 할 수 있는 첫 번째. 시작·중지를 같은 키로 두면 켜고 끄는 키가 된다.
    static func pick(_ actions: [HotKeyAction], state: Transcriber.State, modelReady: Bool, hasText: Bool) -> HotKeyAction? {
        actions.first { $0.isAllowed(state: state, modelReady: modelReady, hasText: hasText) }
    }
}

/// 단축키 설정을 UserDefaults 에 저장한다. 한 번도 바꾸지 않은 것은 기본값, 지운 것은 빈 값으로 남긴다.
struct ShortcutStore {
    let defaults: UserDefaults

    private func name(_ action: HotKeyAction) -> String { "HotKey.\(action.rawValue)" }

    func load() -> [HotKeyAction: Shortcut] {
        var result: [HotKeyAction: Shortcut] = [:]
        for action in HotKeyAction.allCases {
            guard let data = defaults.data(forKey: name(action)) else {
                result[action] = action.defaultShortcut
                continue
            }
            result[action] = try? JSONDecoder().decode(Shortcut.self, from: data)   // 빈 값이면 nil (지운 단축키)
        }
        return result
    }

    func save(_ shortcut: Shortcut?, for action: HotKeyAction) {
        let data = shortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        defaults.set(data, forKey: name(action))
    }
}

/// 다른 앱을 쓰는 중에도 동작하는 전역 단축키. macOS 기본 단축키 등록(Carbon)이라 손쉬운 사용 권한이 필요 없다.
@Observable
final class HotKeys {
    private(set) var shortcuts: [HotKeyAction: Shortcut]
    /// 등록하지 못한 단축키 (시스템이나 다른 앱이 이미 쓰는 조합 등)
    private(set) var failed: Set<HotKeyAction> = []
    /// 설정 칸에서 새 조합을 받는 동안에는 단축키를 잠시 끈다. 켜 두면 기존 조합을 눌렀을 때 입력 대신 동작해 버린다.
    var paused = false {
        didSet { if paused != oldValue { register() } }
    }

    @ObservationIgnored private let store: ShortcutStore
    @ObservationIgnored private let onPress: ([HotKeyAction]) -> Void
    @ObservationIgnored private var refs: [EventHotKeyRef] = []
    @ObservationIgnored private var bindings: [UInt32: [HotKeyAction]] = [:]   // 등록 번호 → 그 조합에 묶인 일

    init(store: ShortcutStore = ShortcutStore(defaults: .standard), onPress: @escaping ([HotKeyAction]) -> Void) {
        self.store = store
        self.onPress = onPress
        shortcuts = store.load()
        installHandler()
        register()
    }

    /// 단축키를 바꾸거나(nil 이면 지우기) 저장하고 다시 등록한다
    func set(_ shortcut: Shortcut?, for action: HotKeyAction) {
        shortcuts[action] = shortcut
        store.save(shortcut, for: action)
        register()
    }

    /// 앱이 끝날 때까지 살아 있는 객체라 핸들러는 지우지 않는다
    private func installHandler() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard let context else { return OSStatus(eventNotHandledErr) }
            Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue().pressed(id.id)
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    private func pressed(_ id: UInt32) {
        guard let actions = bindings[id] else { return }
        onPress(actions)
    }

    /// 지금 설정대로 모두 다시 등록한다. 같은 조합에 묶인 일은 한 번만 등록한다.
    private func register() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        bindings = [:]
        var failures: Set<HotKeyAction> = []
        if !paused {
            var groups: [Shortcut: [HotKeyAction]] = [:]
            for action in HotKeyAction.allCases {
                if let shortcut = shortcuts[action] { groups[shortcut, default: []].append(action) }
            }
            for (number, (shortcut, actions)) in groups.enumerated() {
                let id = EventHotKeyID(signature: OSType(0x5654_5950), id: UInt32(number))   // "VTYP"
                var ref: EventHotKeyRef?
                if RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers, id,
                                       GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                    refs.append(ref)
                    bindings[id.id] = actions
                } else {
                    failures.formUnion(actions)
                }
            }
        }
        if failures != failed { failed = failures }
    }
}
