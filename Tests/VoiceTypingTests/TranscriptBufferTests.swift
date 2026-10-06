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
