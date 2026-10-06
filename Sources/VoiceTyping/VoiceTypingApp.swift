import AppKit
import Carbon.HIToolbox
import SwiftUI

@main
struct VoiceTypingApp: App {
    @State private var model: SpeechModel
    @State private var transcriber: Transcriber
    @State private var paster: Paster
    @State private var hotKeys: HotKeys

    init() {
        #if DEBUG
        // README 화면 캡처용 (디버그 빌드 전용): -ScreenshotState first-run|recording|done|shortcuts 로 실행하면 그 화면으로 시작한다.
        // first-run 은 빈 폴더를 모델 위치로 써서 내려받기 버튼 화면을 만든다.
        let shot = UserDefaults.standard.string(forKey: "ScreenshotState")
        let model = shot == "first-run"
            ? SpeechModel(base: FileManager.default.temporaryDirectory.appending(path: "voicetyping-first-run"))
            : SpeechModel()
        // 캡처할 때는 사용자가 바꾼 단축키 대신 기본값을 보여 준다 (사용자 설정은 읽지도 쓰지도 않음)
        var shortcutStore = ShortcutStore(defaults: .standard)
        if shot != nil, let blank = UserDefaults(suiteName: "local.voicetyping.screenshot") {
            blank.removePersistentDomain(forName: "local.voicetyping.screenshot")
            shortcutStore = ShortcutStore(defaults: blank)
        }
        #else
        let model = SpeechModel()
        let shortcutStore = ShortcutStore(defaults: .standard)
        #endif
        let transcriber = Transcriber(model: model)
        let paster = Paster()
        // 단축키는 메인 스레드(앱 이벤트)에서 불린다
        let hotKeys = HotKeys(store: shortcutStore) { actions in
            MainActor.assumeIsolated { Self.run(actions, transcriber: transcriber, model: model, paster: paster) }
        }
        _model = State(initialValue: model)
        _transcriber = State(initialValue: transcriber)
        _paster = State(initialValue: paster)
        _hotKeys = State(initialValue: hotKeys)
        Task {
            await model.prepare()        // 앱을 켜자마자 모델을 불러와 둔다
            #if DEBUG
            transcriber.stageForScreenshot(shot)
            if shot != nil { paster.stageForScreenshot() }
            #endif
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(transcriber: transcriber, model: model, paster: paster, hotKeys: hotKeys)
        } label: {
            Image(nsImage: Self.icon(recording: transcriber.isBusy))
            if transcriber.isRecording { Text("녹음중") }
        }
        .menuBarExtraStyle(.window)
    }

    @MainActor private static var openedAccessibilitySettings = false

    /// 단축키를 눌렀을 때. 메뉴바 창의 버튼과 같은 조건에서 같은 일을 한다.
    @MainActor
    static func run(_ actions: [HotKeyAction], transcriber: Transcriber, model: SpeechModel, paster: Paster) {
        guard let action = HotKeyAction.pick(actions, state: transcriber.state, modelReady: model.state == .ready,
                                             hasText: !transcriber.buffer.isEmpty) else {
            NSSound.beep()   // 지금은 할 수 없는 일 (예: 녹음 중이 아닌데 중지)
            return
        }
        switch action {
        case .start, .stop:
            transcriber.toggle()
        case .copy:
            Paster.copy(transcriber.buffer.outgoing)
        case .clear:
            transcriber.buffer.clear()
        case .paste:
            Task {
                // 단축키의 ⌃⌥ 를 누른 채로 ⌘V 를 보내면 다른 조합이 되므로 손을 뗄 때까지 기다린다
                _ = await Paster.wait(timeout: .seconds(2)) {
                    CGEventSource.flagsState(.combinedSessionState)
                        .intersection([.maskControl, .maskAlternate, .maskShift, .maskCommand]).isEmpty
                }
                guard let reason = await paster.copyAndPaste(transcriber.buffer.outgoing) else {
                    transcriber.buffer.clear()   // 버튼과 같이, 붙여넣었으면 지운다
                    return
                }
                NSSound.beep()                   // 클립보드 복사까지만 됨. 메뉴바 창이 닫혀 있어 이유를 글로 보여 줄 곳이 없다
                // 권한이 없으면 고칠 곳을 바로 연다. 앱을 켠 동안 한 번만 (누를 때마다 열면 성가시다)
                if reason == Paster.needsAccessibility, !openedAccessibilitySettings {
                    openedAccessibilitySettings = true
                    NSWorkspace.shared.open(Paster.accessibilitySettings)
                }
            }
        }
    }

    /// 평소에는 메뉴바 색을 따르는 마이크, 녹음 중에는 빨간 마이크
    static func icon(recording: Bool) -> NSImage {
        let base = NSImage(systemSymbolName: recording ? "mic.fill" : "mic", accessibilityDescription: "Voice Typing")!
        guard recording, let red = base.withSymbolConfiguration(.init(paletteColors: [.systemRed])) else { return base }
        red.isTemplate = false
        return red
    }
}

/// 화면에 보여 줄 앱 버전. 버전 값은 VERSION 파일에서 build.sh 가 Info.plist 에 넣는다.
enum AppVersion {
    static func label(from info: [String: Any]?) -> String {
        guard let version = info?["CFBundleShortVersionString"] as? String else { return "" }
        return "v" + version
    }
}

struct PopoverView: View {
    @Bindable var transcriber: Transcriber
    let model: SpeechModel
    let paster: Paster
    let hotKeys: HotKeys
    @State private var notice: String?
    #if DEBUG
    @State private var showKeys = UserDefaults.standard.string(forKey: "ScreenshotState") == "shortcuts"   // README 캡처용
    #else
    @State private var showKeys = false
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if model.state != .ready { modelPanel }
            status
            textArea
            actions
            if showKeys { ShortcutPanel(hotKeys: hotKeys) }
            footer
        }
        .padding(14)
        .frame(width: 360)
    }

    private var header: some View {
        HStack {
            Text("Voice Typing").font(.headline)
            Text(AppVersion.label(from: Bundle.main.infoDictionary))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("🔒 한국어 · 온디바이스")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .overlay(Capsule().stroke(.quaternary))
        }
    }

    /// 음성 모델이 준비되기 전: 처음엔 내려받기 버튼, 받는 중엔 진행률, 불러오는 중엔 안내
    private var modelPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.state {
            case .missing:
                Text("처음 한 번 음성 인식 모델(\(SpeechModel.downloadSize))을 내려받아야 합니다. 받은 뒤에는 인터넷 없이 Mac 안에서만 동작합니다.")
                Button("음성 모델 내려받기") { Task { await model.download() } }
                    .buttonStyle(.borderedProminent)
            case .downloading(let progress):
                Text("음성 모델 내려받는 중… \(Int(progress * 100))%")
                ProgressView(value: progress)
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("음성 모델 준비 중… 처음 한 번은 30초쯤 걸립니다")
                }
            case .failed(let message):
                Text("⚠️ \(message)")
                Button("다시 내려받기") { Task { await model.download() } }
            case .ready:
                EmptyView()
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)   // 메뉴바 창에서 안내 문장이 한 줄로 잘리지 않고 줄바꿈되게
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var status: some View {
        switch transcriber.state {
        case .recording where !transcriber.listening:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("마이크 연결 중… 빨간 불이 켜지면 말씀하세요")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
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
        case .finishing:
            Text("마무리 중…").font(.callout).foregroundStyle(.secondary)
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
            if transcriber.isBusy {
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
        let disabled = transcriber.buffer.isEmpty || transcriber.isBusy
        return HStack(spacing: 8) {
            RecordButton(recording: transcriber.isRecording) {
                notice = nil
                transcriber.toggle()
            }
            .disabled(transcriber.state == .finishing || model.state != .ready)
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

    /// 안내 한 줄 + 버튼 줄. [단축키]와 [종료]는 양 끝에 떨어뜨려 잘못 눌리지 않게 한다.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let notice {
                    Text(notice).foregroundStyle(.tint)
                } else {
                    Text("붙여넣기 대상: \(paster.target?.localizedName ?? "없음") · Enter는 직접 누르세요")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            HStack {
                Button { showKeys.toggle() } label: {
                    Label(showKeys ? "단축키 닫기" : "단축키", systemImage: "keyboard")
                }
                Spacer()
                Button { NSApp.terminate(nil) } label: { Label("종료", systemImage: "power") }
            }
            .buttonStyle(.bordered)
            .font(.callout)
        }
    }

    private func copyAndPaste() {
        let popover = NSApp.keyWindow
        Task {
            if let reason = await paster.copyAndPaste(transcriber.buffer.outgoing) {
                notice = reason      // 붙여넣지 못했으면 텍스트를 지우지 않고 이유를 보여 준다
                return
            }
            transcriber.buffer.clear()
            notice = nil
            popover?.close()         // 붙여넣기가 끝났으면 팝오버를 닫는다
        }
    }
}

/// 단축키 설정 칸. 칸을 누른 뒤 새 조합을 누르면 바뀌고, Esc 는 취소, ✕ 는 지우기.
struct ShortcutPanel: View {
    let hotKeys: HotKeys
    @State private var editing: HotKeyAction?
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("단축키 · 다른 앱을 쓰는 중에도 동작").font(.caption).foregroundStyle(.secondary)
            ForEach(HotKeyAction.allCases, id: \.self) { action in
                HStack(spacing: 6) {
                    Text(action.title)
                    Spacer()
                    if hotKeys.failed.contains(action) {
                        Text("쓸 수 없는 조합").font(.caption).foregroundStyle(.orange)
                    }
                    Button { listen(for: action) } label: {
                        Text(editing == action ? "키를 누르세요…" : hotKeys.shortcuts[action]?.display ?? "없음")
                            .frame(width: 104)
                    }
                    Button { hotKeys.set(nil, for: action) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("지우기")
                        .disabled(hotKeys.shortcuts[action] == nil)
                }
            }
            Text("칸을 누르고 새 조합 입력 (⌃·⌥·⌘ 중 하나 이상) · Esc 취소").font(.caption2).foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(10)
        .background(.background.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
        .onDisappear { finish() }
        // 키를 받는 중에 창이 닫히면 멈춰 둔 단축키를 다시 켠다
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in finish() }
    }

    private func listen(for action: HotKeyAction) {
        finish()
        editing = action
        hotKeys.paused = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                finish()
            } else if let shortcut = Shortcut(keyCode: event.keyCode, modifiers: event.modifierFlags,
                                              characters: event.charactersIgnoringModifiers) {
                hotKeys.set(shortcut, for: action)
                finish()
            }
            return nil   // 키를 받는 동안에는 글자 칸 등으로 넘기지 않는다
        }
    }

    private func finish() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        editing = nil
        hotKeys.paused = false
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
