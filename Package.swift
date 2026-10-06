// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VoiceTyping",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Whisper 음성 인식을 Mac 안(Core ML·Neural Engine)에서 돌린다
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.0"),
    ],
    targets: [
        .executableTarget(name: "VoiceTyping", dependencies: [.product(name: "WhisperKit", package: "WhisperKit")]),
        .testTarget(name: "VoiceTypingTests", dependencies: ["VoiceTyping", .product(name: "WhisperKit", package: "WhisperKit")]),
    ],
    // AVAudioEngine 탭 콜백이 Swift 6 엄격한 동시성 검사와 맞지 않아 Swift 5 모드로 빌드한다
    swiftLanguageModes: [.v5]
)
