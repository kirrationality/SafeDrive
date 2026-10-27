import AVFoundation

/*
 SpeechSynthesizer = SafeDrive AI's text-to-speech service.

 It uses Apple's AVSpeechSynthesizer to speak AI responses
 and other app messages aloud.

*/


@MainActor
final class SpeechSynthesizer: NSObject {

    private let synthesizer = AVSpeechSynthesizer()

    // Tracks the sentence currently being spoken.
    private var currentUtterance: AVSpeechUtterance?

    // Lets the conversation resume when speech finishes or is stopped.
    private var finishContinuation: CheckedContinuation<Void, Never>?

    private var speechFinished = true
    
    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // Speak using your existing Apple voice.
    func speak(_ text: String) {
                
        // Stop any previous response before starting another.
        stopSpeaking()
        
        let utterance = AVSpeechUtterance(string: text)

        // Select the exact Premium voice installed on your iPhone. Ava/Zoe
        utterance.voice = AVSpeechSynthesisVoice(
            identifier: "com.apple.voice.premium.en-US.Zoe"
        )
        utterance.rate = 0.5

        currentUtterance = utterance
        speechFinished = false

        synthesizer.speak(utterance)
    }

    // Wait for Apple's actual completion/cancellation callback.
    func waitUntilFinished() async {

        guard !speechFinished else { return }

        await withCheckedContinuation { continuation in
            finishContinuation = continuation
        }
    }

    // Stop speaking immediately; the conversation can then resume.
    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        completeCurrentSpeech()
    }

    // Mark the current utterance finished and resume any waiting task.
    private func completeCurrentSpeech(
        for utteranceID: ObjectIdentifier? = nil
    ) {

        // Ignore a late callback from an older sentence.
        if let utteranceID {
            guard let currentUtterance,
                  ObjectIdentifier(currentUtterance) == utteranceID
            else {
                return
            }
        }

        currentUtterance = nil
        speechFinished = true

        let continuation = finishContinuation
        finishContinuation = nil
        continuation?.resume()
    }
}

// Apple calls these when speaking actually starts, finishes or is cancelled.
extension SpeechSynthesizer: AVSpeechSynthesizerDelegate {
    
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        let utteranceID = ObjectIdentifier(utterance)
        
        Task { @MainActor in
            self.completeCurrentSpeech(for: utteranceID)
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        let utteranceID = ObjectIdentifier(utterance)
        
        Task { @MainActor in
            self.completeCurrentSpeech(for: utteranceID)
        }
    }
}
