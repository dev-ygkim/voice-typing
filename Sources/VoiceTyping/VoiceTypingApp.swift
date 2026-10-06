import AppKit
import SwiftUI

@main
struct VoiceTypingApp: App {
    @State private var model: SpeechModel
    @State private var transcriber: Transcriber
    @State private var paster = Paster()

    init() {
        let model = SpeechModel()
        _model = State(initialValue: model)
        _transcriber = State(initialValue: Transcriber(model: model))
        Task { await model.prepare() }   // 앱을 켜자마자 모델을 불러와 둔다
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(transcriber: transcriber, model: model, paster: paster)
        } label: {
            Image(nsImage: Self.icon(recording: transcriber.isBusy))
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
    /// 제목 옆 버전. README 화면 이미지를 만들 때는 앱 밖에서 그리므로 바깥에서 넣어 준다.
    var version = AppVersion.label(from: Bundle.main.infoDictionary)
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if model.state != .ready { modelPanel }
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
            Text(version)
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
