import Foundation
import Speech
import AVFoundation

/*
 SpeechRecognizer = SafeDrive AI's speech-to-text service.

 It uses Apple's SpeechAnalyzer and SpeechTranscriber to
 convert microphone audio into recognized text.
*/


final class SpeechRecognizer {

    // Apple's speech-to-text module.
    private var transcriber:
        SpeechTranscriber?

    // Manages the speech-analysis session.
    private var analyzer:
        SpeechAnalyzer?

    // Sends microphone audio into SpeechAnalyzer.
    private var inputBuilder:
        AsyncStream<AnalyzerInput>.Continuation?

    // Audio format required by SpeechAnalyzer.
    private var analyzerFormat:
        AVAudioFormat?

    // Converts microphone audio into the format required by SpeechAnalyzer.
    private let converter =
        BufferConverter()

    // Reads speech results while listening.
    private var resultTask:
        Task<String, Never>?

    // Sends recognized text back to ContentView.
    private var onResult:
        (@Sendable (String, Bool) -> Void)?

    // Start a new speech-recognition session.
    func startRecognition(
        onResult:
            @escaping @Sendable
            (String, Bool) -> Void
    ) async -> Bool {

        self.onResult = onResult

        guard SpeechTranscriber.isAvailable else {

            print(
                "SpeechTranscriber is not available."
            )

            return false
        }

        // Find supported US English.
        guard let locale =
                await SpeechTranscriber
                    .supportedLocale(
                        equivalentTo:
                            Locale(
                                identifier: "en-US"
                            )
                    )
        else {

            print(
                "English speech recognition is not supported."
            )

            return false
        }

        let transcriber =
            SpeechTranscriber(
                locale: locale,
                preset:
                    .progressiveTranscription
            )

        // Install the speech model if needed.
        do {

            if let request =
                try await AssetInventory
                    .assetInstallationRequest(
                        supporting:
                            [transcriber]
                    ) {

                try await request
                    .downloadAndInstall()
            }

        } catch {

            print(
                "Could not install speech model:",
                error
            )

            return false
        }

        // Find the format SpeechAnalyzer needs.
        guard let analyzerFormat =
                await SpeechAnalyzer
                    .bestAvailableAudioFormat(
                        compatibleWith:
                            [transcriber]
                    )
        else {

            print(
                "No compatible speech audio format."
            )

            return false
        }

        let (
            inputSequence,
            inputBuilder
        ) =
            AsyncStream.makeStream(
                of: AnalyzerInput.self
            )

        let analyzer =
            SpeechAnalyzer(
                modules:
                    [transcriber]
            )

        // Save the current session.
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.inputBuilder = inputBuilder
        self.analyzerFormat =
            analyzerFormat

        // Read transcription results.
        resultTask = Task {

            await Self.readResults(
                from: transcriber,
                onResult: onResult
            )
        }

        // Start SpeechAnalyzer.
        do {

            try await analyzer.start(
                inputSequence:
                    inputSequence
            )

        } catch {

            print(
                "Speech analyzer failed:",
                error
            )

            resultTask?.cancel()
            resultTask = nil

            return false
        }

        print(
            "Speech recognition started"
        )

        return true
    }

    // Read live transcription results.
    private static func readResults(
        from transcriber:
            SpeechTranscriber,
        onResult:
            @escaping @Sendable
            (String, Bool) -> Void
    ) async -> String {

        var finalizedText = ""
        var volatileText = ""

        do {

            for try await result
                in transcriber.results {

                let text =
                    String(
                        result.text.characters
                    )

                guard !text.isEmpty else {
                    continue
                }

                if result.isFinal {

                    finalizedText += text
                    volatileText = ""

                } else {

                    volatileText = text
                }

                let currentText =
                    (
                        finalizedText +
                        volatileText
                    )
                    .trimmingCharacters(
                        in:
                            .whitespacesAndNewlines
                    )

                onResult(
                    currentText,
                    false
                )
            }

        } catch {

            print(
                "Speech recognition error:",
                error
            )
        }

        return
            (
                finalizedText +
                volatileText
            )
            .trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )
    }

    // Give microphone audio to SpeechAnalyzer.
    func makeAudioHandler()
        -> (AVAudioPCMBuffer) -> Void {

        guard let inputBuilder,
              let analyzerFormat
        else {

            return { _ in }
        }

        return { [converter] buffer in

            do {

                let converted =
                    try converter
                        .convertBuffer(
                            buffer,
                            to:
                                analyzerFormat
                        )

                let input =
                    AnalyzerInput(
                        buffer:
                            converted
                    )

                inputBuilder.yield(
                    input
                )

            } catch {

                print(
                    "Audio conversion error:",
                    error
                )
            }
        }
    }

    // Stop recognition and return the final text.
    func stopRecognition()
        async -> String {

        guard let inputBuilder,
              let analyzer
        else {

            return ""
        }

        // No more microphone audio.
        inputBuilder.finish()

        do {

            try await analyzer
                .finalizeAndFinishThroughEndOfInput()

        } catch {

            print(
                "Could not finalize speech:",
                error
            )
        }

        // Wait for the final transcript.
        let finalText =
            await resultTask?.value ?? ""

        onResult?(
            finalText,
            true
        )

        print(
            "Final speech:",
            finalText
        )

        print(
            "Speech recognition stopped"
        )

        // Clean up the session.
        resultTask = nil
        self.inputBuilder = nil
        self.analyzer = nil
        self.transcriber = nil
        self.analyzerFormat = nil
        self.onResult = nil

        return finalText
    }
}

// Converts microphone audio into the format
// required by SpeechAnalyzer.

private final class BufferConverter {

    private var converter:
        AVAudioConverter?

    func convertBuffer(
        _ buffer: AVAudioPCMBuffer,
        to format: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {

        // No conversion needed.
        if buffer.format == format {
            return buffer
        }

        // Create a converter if the format changed.
        if converter == nil ||
            converter?.outputFormat != format {

            converter =
                AVAudioConverter(
                    from:
                        buffer.format,
                    to:
                        format
                )

            converter?.primeMethod =
                .none
        }

        guard let converter else {
            throw ConversionError.failed
        }

        let sampleRateRatio =
            converter
                .outputFormat
                .sampleRate /
            converter
                .inputFormat
                .sampleRate

        let frameCapacity =
            AVAudioFrameCount(
                (
                    Double(
                        buffer.frameLength
                    ) *
                    sampleRateRatio
                )
                .rounded(.up)
            )

        guard let outputBuffer =
                AVAudioPCMBuffer(
                    pcmFormat:
                        converter.outputFormat,
                    frameCapacity:
                        frameCapacity
                )
        else {
            throw ConversionError.failed
        }

        var conversionError:
            NSError?

        var bufferProcessed = false

        let status =
            converter.convert(
                to:
                    outputBuffer,
                error:
                    &conversionError
            ) { _, inputStatus in

                if bufferProcessed {

                    inputStatus.pointee =
                        .noDataNow

                    return nil
                }

                bufferProcessed = true

                inputStatus.pointee =
                    .haveData

                return buffer
            }

        guard status != .error else {

            throw conversionError
                ?? ConversionError.failed
        }

        return outputBuffer
    }

    private enum ConversionError:
        Error {

        case failed
    }
}
