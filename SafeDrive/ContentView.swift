/*
PURPOSE:
Displays the SafeDrive home screen and coordinates AI voice conversations,
safety alerts, and DAMS camera/GPS monitoring.

IMPORTS:
SwiftUI builds the screen and manages its state.

IMPORTANT:
- AudioManager handles microphone audio.
- SpeechRecognizer converts speech to text.
- AIService generates on-device AI responses.
- SpeechSynthesizer speaks the AI responses.
- DAMSCameraMonitor detects driver attention issues.
- DAMSSpeedMonitor monitors vehicle speed using GPS.
- Safety alerts interrupt ongoing conversations.
- EmergencyContactsView provides the Emergency tab.
*/

import SwiftUI

struct ContentView: View {

    // MARK: - Screen state
    @State private var isAIListening = false
    @State private var isAIConversationActive = false
    @State private var isFinishingUserTurn = false
    @State private var isAIProcessing = false
    @State private var currentSafetyAlertToDisplay = "" // DROWSY/DISTRACTED/SPEEDING

    // Every new conversation/alert gets a new number. Slow tasks (AI,
    // speech) check it when they wake up; if it changed, they're stale
    // and quietly stop instead of talking over the newer conversation.
    @State private var turnID = 0

    // Service objects live for the whole app run.
    @State private var audioManager = AudioManager()
    @State private var speechRecognizer = SpeechRecognizer()
    @State private var speechSynthesizer = SpeechSynthesizer()
    @State private var aiService = AIService()

    //-- DAMS implementation
    // DAMS monitoring objects manage the camera and GPS.
    @State private var damsCameraMonitor = DAMSCameraMonitor()
    @State private var damsSpeedMonitor = DAMSSpeedMonitor()

    // Handles alerts received from the Raspberry Pi.
    @State private var piMonitor = PiAlertMonitor()

    // Selects which device monitors the driver.
    @State private var selectedMonitoringMode = "iPhone"
    
    // State values tell SwiftUI if monitoring on/off
    @State private var isDAMSMonitoring = false
    @State private var damsStatus = "" // DAMS camera and GPS error status


    
    // MARK: - Conversation State Checks
    
    // True only if this task still belongs to the live conversation.
    private func isCurrentTurn(_ expectedTurnID: Int) -> Bool {
        isAIConversationActive && expectedTurnID == turnID
    }

    // Switches monitoring devices. The new mode starts OFF.
    private func switchMonitoringMode(to mode: String) {

        // Stop whichever monitoring system was previously active.
        if mode == "Raspberry Pi" {
            damsCameraMonitor.stop()
            damsSpeedMonitor.stop()
        } else {
            piMonitor.stop()
        }

        // Reset monitoring status when switching devices.
        isDAMSMonitoring = false
        damsStatus = ""
        currentSafetyAlertToDisplay = ""

        // End any active AI conversation.
        if isAIConversationActive {
            Task { await endAIConversation() }
        }
    }
    
    
    
    // MARK: - DAMS Monitoring UI

    // Displays the selected device and its START/STOP button.
    private func monitoringFrame() -> some View {

        VStack(spacing: 0) {

            if selectedMonitoringMode == "Raspberry Pi" {

                // Display the Raspberry Pi camera indicator.
                VStack(spacing: 15) {
                    Image(systemName: "video.fill")
                        .font(.system(size: 65))
                        //.foregroundStyle(.secondary)
                        .foregroundStyle(isDAMSMonitoring ? .green : .secondary)

                    Text(isDAMSMonitoring
                         ? "External Monitoring in Progress"
                         : "External Monitoring Off")
                        .font(.headline)
                    
                    // adding animation effect when Pi monitoring on
                    // --start animation
                    if isDAMSMonitoring {

                        PhaseAnimator([0, 1, 2, 3, 4]) { activeBar in

                            HStack(spacing: 5) {
                                ForEach(0..<5, id: \.self) { bar in
                                    Capsule()
                                        .fill(.green)
                                        .frame(
                                            width: 5,
                                            height: bar == activeBar ? 22 : 8
                                        )
                                }
                            }

                        } animation: { _ in
                            .easeInOut(duration: 0.3)
                        }
                    }
                    //--end animation
                }
                .frame(maxWidth: .infinity)
                .frame(height: 310)

            } else if isDAMSMonitoring {

                // Display the live iPhone camera.
                DAMSPreviewView(session: damsCameraMonitor.session)
                    .frame(maxWidth: .infinity)
                    .frame(height: 310)

            } else {

                // Display an iPhone indicator when monitoring is off.
                VStack(spacing: 15) {
                    Image(systemName: "iphone")
                        .font(.system(size: 65))
                        .foregroundStyle(.secondary)

                    Text("iPhone Monitoring Off")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 310)
            }

            // Separate the camera area from the button row.
            Divider()

            // Same monitoring button for both devices.
            Button(isDAMSMonitoring ? "STOP MONITORING" : "START MONITORING") {
                toggleMonitoring()
            }
            .buttonStyle(.borderedProminent)
            .tint(isDAMSMonitoring ? .red : .green)
            .frame(maxWidth: .infinity)
            .frame(height: 69)
            .background(Color.primary.opacity(0.05))
        }
        .frame(maxWidth: .infinity)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    

    // MARK: - DAMS Monitoring Controls

    // Starts or stops monitoring for the selected device.
    private func toggleMonitoring() {

        if isDAMSMonitoring {

            // Stop the selected monitoring system.
            if selectedMonitoringMode == "iPhone" {
                damsCameraMonitor.stop()
                damsSpeedMonitor.stop()
            } else {
                piMonitor.stop()
            }

            // Clear the monitoring status and previous alert.
            isDAMSMonitoring = false
            damsStatus = ""
            currentSafetyAlertToDisplay = ""

            // End any active AI conversation.
            if isAIConversationActive {
                Task { await endAIConversation() }
            }

        } else {

            // Start the selected monitoring system.
            if selectedMonitoringMode == "iPhone" {
                damsCameraMonitor.start()
                damsSpeedMonitor.start()
            } else {
                piMonitor.start()
            }

            isDAMSMonitoring = true
            damsStatus = ""
        }
    }
    
    
    // MARK: - Safety alerts

    // Called by the Pi (HTTP) or by the test buttons.
    private func triggerSafetyAlert(_ alert: SafetyAlert) async {
        
        // Identify this alert so older tasks cannot take over.
        turnID += 1
        let currentTurnID = turnID
    
        // Display the alert immediately.
        print("ALERT RECEIVED:", alert.rawValue)
        currentSafetyAlertToDisplay = alert.rawValue.uppercased() // DROWSY/DISTRACTED/SPEEDING
        
        // Stop the previous conversation before handling the new alert.
        await interruptAIConversation()

        // Ignore this alert if a newer alert arrived
        guard turnID == currentTurnID else { return }

        isAIConversationActive = true
        isAIProcessing = false
        aiService.startConversation(for: alert)
        
        // Speak the predefined warning immediately.
        audioManager.prepareSession()
        speechSynthesizer.speak(alert.fallbackMessage)

        await speechSynthesizer.waitUntilFinished()
        guard isCurrentTurn(currentTurnID) else { return }

        // Listen for the driver, then let AI handle the conversation.
        await startAIListening()
        

    }

    
    // MARK: - Interrupting a Conversation
    
    // Stop everything quickly, without the goodbye speech.
    private func interruptAIConversation() async {
        isAIConversationActive = false
        isAIProcessing = false
        isFinishingUserTurn = false
        if isAIListening { _ = await stopAIListening() }
        speechSynthesizer.stopSpeaking()
    }


    
    // MARK: - Conversation flow

    // Open the mic for one turn.
    private func startAIListening() async {
        guard isAIConversationActive, !isAIListening, !isFinishingUserTurn else { return }

        let expectedTurnID = turnID
        

        guard await audioManager.requestMicrophonePermission() else {
            await stopWithMessage("I need microphone permission before we can talk.")
            return
        }

        // 1) Start Apple's speech recognition.
        let speechRecognitionStarted = await speechRecognizer.startRecognition { _, _ in }
        
        // The user may have tapped END while we were waiting above.
        guard isCurrentTurn(expectedTurnID) else {
            if speechRecognitionStarted { _ = await speechRecognizer.stopRecognition() }
            return
        }
        guard speechRecognitionStarted else {
            await stopWithMessage("I'm having trouble starting speech recognition.")
            return
        }

        // 2) Start the mic; it reports when the driver goes quiet.
        let microphoneStarted = audioManager.startListening(
            onAudio: speechRecognizer.makeAudioHandler(),
            onSilence: {
                Task { @MainActor in
                    await finishUserTurn()
                }
            }
        )

        guard microphoneStarted else {
            _ = await speechRecognizer.stopRecognition()
            await stopWithMessage("I couldn't start the microphone.")
            return
        }

        isAIListening = true
    }

    // Driver stopped talking: get the final text, check for exit, ask the AI.
    private func finishUserTurn() async {
        guard isAIConversationActive, isAIListening, !isFinishingUserTurn else { return }

        let myTurn = turnID
        isFinishingUserTurn = true

        let finalText = await stopAIListening()
        
        print("EXIT CHECK INPUT:", "[\(finalText)]")
        print("SHOULD END:", shouldEndConversation(finalText))
        
        guard isCurrentTurn(myTurn) else { return }   // interrupted; flags already reset

        let trimmedFinalText = finalText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Heard only noise: just listen again.
        guard !trimmedFinalText.isEmpty else {
            isFinishingUserTurn = false
            await startAIListening()
            return
        }

        // Exit phrases are handled here, not sent to the AI.
        if shouldEndConversation(trimmedFinalText) {
            isFinishingUserTurn = false
            await endAIConversation()
            return
        }

        let shouldContinueConversation = await askAI(trimmedFinalText, turn: myTurn)
        guard isCurrentTurn(myTurn) else { return }
        isFinishingUserTurn = false

        if shouldContinueConversation { await startAIListening() }
    }

    // Ask the AI and speak the reply. Returns true if we should keep listening.
    private func askAI(_ userMessage: String, turn myTurn: Int) async -> Bool {
        isAIProcessing = true

        do {
            let aiResponse = try await aiService.sendMessage(userMessage)
        
            guard isCurrentTurn(myTurn) else { return false }

            isAIProcessing = false

            speechSynthesizer.speak(aiResponse)
            await speechSynthesizer.waitUntilFinished()
            return isCurrentTurn(myTurn)

        } catch {
            print("AI ERROR:", error)
            guard isCurrentTurn(myTurn) else { return false }

            if case AIService.AIError.modelUnavailable = error {
                await stopWithMessage("My on-device AI isn't ready. Please check Apple Intelligence settings.")
            } else {
                await stopWithMessage("I couldn't come up with an answer. Please try again.")
            }
            return false
        }
    }

    // Stop the mic and get Apple's finalized transcript.
    private func stopAIListening() async -> String {
        isAIListening = false


        audioManager.stopListening()
    
        let finalText = await speechRecognizer.stopRecognition()
        return finalText
    }

    // MARK: - Ending


    // Check whether the driver said something that should end the conversation.
    private func shouldEndConversation(_ text: String) -> Bool {

        // Normalize the transcript so punctuation and capitalization don't matter.
        let cleaned = text
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(
                of: "[^a-z0-9' ]",
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "\\s+",
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Ignore polite filler words at the beginning, such as "Okay, bye."
        let fillerWords: Set<String> = [
            "ok", "okay", "alright", "thanks", "thank",
            "you", "hey", "yeah"
        ]

        // Split the transcript into words so we can remove leading fillers.
        var words = cleaned.split(separator: " ").map(String.init)

        // Remove filler words only from the beginning of the sentence.
        while let first = words.first, fillerWords.contains(first) {
            words.removeFirst()
        }

        // Rebuild the remaining words into a single phrase.
        let phrase = words.joined(separator: " ")

        // These phrases tell the app that the driver wants to stop talking.
        let exitPhrases: Set<String> = [
            "bye", "goodbye", "good bye", "bye bye",
            "stop", "exit", "quit",
            "see you", "see you later", "talk to you later",
            "i'm done", "im done", "i am done",
            "i'm finished", "im finished", "i am finished",
            "i'm good", "im good", "i am good", "i'm good now",
            "that's all", "thats all", "that's all for now",
            "i'm all set", "im all set", "i am all set",
            "stop conversation", "end conversation",
            "end the conversation",
            "i want to stop", "i want to end this",
            "i'm leaving", "im leaving"
        ]

        // Match a complete exit phrase, even if speech recognition adds words
        // before or after it. Avoid matching a phrase inside another word.
        return exitPhrases.contains { exit in
            phrase == exit ||
            phrase.hasPrefix(exit + " ") ||
            phrase.hasSuffix(" " + exit) ||
            phrase.contains(" " + exit + " ")
        }
    }

    
    // Say goodbye, stop the conversation, and return to the start screen.
    private func endAIConversation() async {
        // Remember which conversation is ending so we can detect if a new
        // safety alert starts while the goodbye message is playing.
        let endingTurnID = turnID
      
        isAIConversationActive = false // Mark the conversation as ended so the buttons can update.
        turnID += 1      // cancels any slow speech task still running
        
        // Stop the microphone and speech recognition if still listening
        if isAIListening { _ = await stopAIListening() }

        // Reset these immediately so the interface doesn't stay disabled.
        isAIProcessing = false
        isFinishingUserTurn = false

        // Stop any speech that was already playing.
        speechSynthesizer.stopSpeaking()
        
        // Say goodbye before clearing the displayed response.
        audioManager.prepareSession()
        speechSynthesizer.speak("Okay, Bye!")
        await speechSynthesizer.waitUntilFinished()

        // A new alert may have arrived while the goodbye was playing.
        // If so, stop this old conversation from cleaning up the new alert.
        guard turnID == endingTurnID + 1 else { return }
        
        //-- No new alert arrived, so it is safe to finish cleaning up.
        // Release the audio session now that goodbye has finished
        audioManager.deactivateAudioSession()
        
        // Clear the AI's conversation history for the next session.
        aiService.resetConversation()

        // Clear the screen so the next conversation starts fresh.
        currentSafetyAlertToDisplay = ""
    }

    // Stop the conversation after an error, tell the driver what happened,
    // and prevent the microphone from reopening.
    private func stopWithMessage(_ message: String) async {

        // Mark the conversation as inactive so the safety buttons can re-enable.
        isAIConversationActive = false

        // Invalidate any older AI or speech task that is still running.
        turnID += 1

        // Remember this error message's turn ID so we can detect a newer alert.
        let errorTurnID = turnID
        
        // Clear the flags that indicate AI processing or turn completion is active.
        isAIProcessing = false
        isFinishingUserTurn = false

        // Stop the microphone and speech recognition if they are active.
        if isAIListening {
            _ = await stopAIListening()
        }

        // Stop any speech that is already playing.
        speechSynthesizer.stopSpeaking()

        // Prepare the audio session so the app can speak the error message.
        audioManager.prepareSession()

        // Speak the error message aloud.
        speechSynthesizer.speak(message)

        // Wait until the spoken message finishes before releasing the audio session.
        await speechSynthesizer.waitUntilFinished()
        
        // Do not clean up audio if a newer conversation has started.
        guard turnID == errorTurnID else { return }

        // Deactivate the audio session after the message has finished.
        audioManager.deactivateAudioSession()
    }
    

    // MARK: - Screen

    private var aiConversationStatus: String {
        if isAIProcessing { return "Thinking..." }
        if isAIListening {return "Listening..."} else {return ""}
    }

    var body: some View {
        TabView {
            
            VStack(spacing: 15) {
                
                //-- App Title + Subtitle
                Text("SafeDrive")
                    .font(.system(size: 50, weight: .bold))
                    .foregroundStyle(.blue)
                    .frame(maxWidth: .infinity)
                
                Text("Your AI Co-Pilot to keep you safe")
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary) // Keep the subtitle subtler than the blue title.
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 10)
                
                //-- Safety Alert Status Display (DISTRACTED/DROWSY/SPEEDING)
                if !currentSafetyAlertToDisplay.isEmpty {
                    Text(currentSafetyAlertToDisplay)
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundStyle(.white) // White text contrasts with the red banner.
                        .frame(maxWidth: .infinity) // Stretch the banner across the available width.
                        .padding() // Add space around the alert text.
                        .background(.red) // Red background draws attention to the safety alert.
                        .clipShape(RoundedRectangle(cornerRadius: 12)) // Round the banner corners.
                }
                
                /*
                 //-- UNCOMMENT Test buttons: WHEN TESTING WITHOUT A CAMERA
                 HStack(spacing: 10) {
                 Button("DROWSY DRIVER") { Task { await triggerSafetyAlert(.drowsy) } }
                 Button("DISTRACTED DRIVER") { Task { await triggerSafetyAlert(.distracted) } }
                 Button("SPEEDING DRIVER") { Task { await triggerSafetyAlert(.speeding) } }
                 }
                 .buttonStyle(.bordered)
                 .disabled(isAIConversationActive || isAIProcessing) // Disable buttons when conversation active or AI is thinking
                 */
                
                
                // Select which device monitors the driver.
                HStack(spacing: 4) {

                    Button {
                        selectedMonitoringMode = "iPhone"
                    } label: {
                        Label("iPhone", systemImage: "iphone")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(selectedMonitoringMode == "iPhone"
                                        ? Color(.systemBackground) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    Button {
                        selectedMonitoringMode = "Raspberry Pi"
                    } label: {
                        Label("External", systemImage: "cpu")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(selectedMonitoringMode == "Raspberry Pi"
                                        ? Color(.systemBackground) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .buttonStyle(.plain)
                .labelStyle(.titleAndIcon)
                .padding(4)
                .background(Color(.systemGray5))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .onChange(of: selectedMonitoringMode) { _, mode in
                    switchMonitoringMode(to: mode)
                }
                
                
                // Display iPhone camera controls or Raspberry Pi indicator.
                monitoringFrame()
                
                // For DAMS monitoring on/off status
                Text(damsStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                // For AI Conversation Stauts Only -- Progress spinning wheel
                ProgressView {Text(aiConversationStatus).foregroundStyle(.secondary)}
                    .opacity(aiConversationStatus.isEmpty ? 0 : 1)
            } // --end VStack
            .padding()
            .task {
                // Keep the screen on while the phone is on the dash.
                UIApplication.shared.isIdleTimerDisabled = true
                
                //-- DAMS implementation
                
                // Send camera alerts through the existing safety-alert flow.
                damsCameraMonitor.onAlert = { alert in
                    // Ignore alerts unless iPhone monitoring is active.
                    guard isDAMSMonitoring && selectedMonitoringMode == "iPhone" else { return }

                    Task { await triggerSafetyAlert(alert) }
                }
                
                // Send GPS alerts through the same safety-alert flow.
                damsSpeedMonitor.onAlert = { alert in
                    // Ignore alerts unless iPhone monitoring is active.
                    guard isDAMSMonitoring && selectedMonitoringMode == "iPhone" else { return }

                    Task { await triggerSafetyAlert(alert) }
                }
                
                // Raspberry Pi alerts use the same AI conversation function.
                piMonitor.onAlert = { alert in
                    // Ignore alerts unless Raspberry Pi monitoring is active.
                    guard isDAMSMonitoring && selectedMonitoringMode == "Raspberry Pi" else { return }

                    Task { await triggerSafetyAlert(alert) }
                }
                
                // Display camera errors, but ignore normal camera status messages.
                damsCameraMonitor.onStatus = { message in
                    guard message.hasPrefix("ERROR:") else { return }
                    
                    damsStatus = "Camera error: \(message.dropFirst("ERROR:".count).trimmingCharacters(in: .whitespaces))"
                    
                }
                
                // Display GPS errors, but ignore normal GPS status messages.
                damsSpeedMonitor.onStatus = { message in
                    guard message.hasPrefix("ERROR:") else { return }
                    
                    damsStatus = "GPS error: \(message.dropFirst("ERROR:".count).trimmingCharacters(in: .whitespaces))"
                }
                
            } // --end .task for VStack
            .tabItem {
                Label("Drive", systemImage: "car.side")
            }

            EmergencyContactsView()
                .tabItem {
                    Label("Emergency", systemImage: "phone.fill")
                }
        } // --end TabView
    } // --end body
} // --end ContentView

#Preview {
    ContentView()
}
