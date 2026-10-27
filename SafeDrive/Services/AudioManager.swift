import AVFoundation
import Accelerate 

/* AudioManager = the iPhone's microphone + audio session.
 It does three jobs:
    1. Configure the audio session (prepareSession)
    2. Stream mic audio to the speech recognizer (startListening)
    3. Notice when the driver stops talking (checkForSilence)
*/

final class AudioManager {

    private let audioEngine = AVAudioEngine()
    private var tapInstalled = false

    // --- Silence detector settings ---
    // A turn ends after the driver speaks, then is quiet for this long.
    // 1.5s feels natural and is faster than the old 2.0s.
    private let silenceDuration: TimeInterval = 1.5
    // Never treat anything quieter than this as speech.
    private let minSpeechLevel: Float = 0.015
    // Running estimate of background noise (engine, road, wind).
    // "Speech" must be 3x louder than this, so a noisy car doesn't
    // count as speech forever.
    private var noiseFloor: Float = 0.005

    // --- Detector state (touched from the audio thread) ---
    private var hasDetectedSpeech = false
    private var silenceStartTime: TimeInterval?
    private var silenceReported = false

    // MARK: - Permission

    func requestMicrophonePermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    // MARK: - Audio session

    // Call this BEFORE speaking or listening. The old code only set
    // this up when the mic started, so a safety alert could be spoken
    // with the wrong audio setup (e.g. silent if the ring switch is on).
    @discardableResult
    func prepareSession() -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                // defaultToSpeaker: play through the loud speaker, not the earpiece
                // allowBluetoothHFP: use a car's Bluetooth mic/speaker.
                //   (Trade-off: Bluetooth calls sound lower quality.
                //    Remove it if you only use the phone speaker.)
                options: [.defaultToSpeaker, .allowBluetoothHFP]
            )
            try session.setActive(true)
            return true
        } catch {
            print("Audio session error:", error)
            return false
        }
    }

    // MARK: - Listening

    // Start the mic. `onAudio` receives raw audio for speech recognition.
    // `onSilence` fires once when the driver finishes talking.
    func startListening(
        onAudio: @escaping (AVAudioPCMBuffer) -> Void,
        onSilence: @escaping @Sendable () -> Void
    ) -> Bool {

        guard prepareSession() else { return false }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0, format.channelCount > 0 else {
            print("No usable microphone input.")
            deactivateAudioSession()
            return false
        }

        // Fresh detector for each turn.
        hasDetectedSpeech = false
        silenceStartTime = nil
        silenceReported = false
        noiseFloor = 0.005

        if tapInstalled {
            inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        // A "tap" gives us a copy of every small chunk of mic audio.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) {
            [weak self] buffer, _ in
            
            // Ignore empty buffers before sending audio to other services.
            guard buffer.frameLength > 0 else { return }
            
            onAudio(buffer)
            self?.checkForSilence(in: buffer, onSilence: onSilence)
        }
        tapInstalled = true
        audioEngine.prepare()

        do {
            try audioEngine.start()
            return true
        } catch {
            print("Could not start microphone:", error)
            inputNode.removeTap(onBus: 0)
            tapInstalled = false
            audioEngine.stop()
            deactivateAudioSession()
            return false
        }
    }

    // Measure loudness of each chunk and decide if the driver is done.
    private func checkForSilence(
        in buffer: AVAudioPCMBuffer,
        onSilence: @escaping @Sendable () -> Void
    ) {
        guard let channel = buffer.floatChannelData?.pointee,
              buffer.frameLength > 0 else { return }

        // RMS = a standard "average loudness" number. vDSP does it fast.
        var rms: Float = 0
        vDSP_rmsqv(channel, 1, &rms, vDSP_Length(buffer.frameLength))

        let threshold = max(minSpeechLevel, noiseFloor * 3)
        let now = ProcessInfo.processInfo.systemUptime

        if rms > threshold {
            // Driver is talking.
            hasDetectedSpeech = true
            silenceStartTime = nil
            silenceReported = false
            return
        }

        // Quiet chunk: slowly learn what "background noise" sounds like.
        noiseFloor = noiseFloor * 0.95 + rms * 0.05

        guard hasDetectedSpeech, !silenceReported else { return }

        if silenceStartTime == nil { silenceStartTime = now }

        if let start = silenceStartTime, now - start >= silenceDuration {
            silenceReported = true          // report only once per turn
            DispatchQueue.main.async { onSilence() }
        }
    }

    // MARK: - Stopping

    // Stop the mic but keep the session active so speech can play.
    func stopListening() {
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if audioEngine.isRunning { audioEngine.stop() }
    }

    // Give audio back to the system (e.g. Maps, music) when done.
    func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
    }
}
