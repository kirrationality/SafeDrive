import Foundation
import FoundationModels

/*
 AIService = the iPhone's on-device AI brain.

 It does two jobs:
   1. Manage the AI conversation and generate replies (sendMessage)
   2. Handle safety instructions and errors (SafetyAlert, AIError)
 
 It uses Apple's Foundation Models framework to generate spoken
 responses without sending the conversation to a remote AI server.

*/


// The enum lets us identify an alert and get the matching AI instructions.
enum SafetyAlert: String , Hashable {
    case drowsy = "DROWSY"
    case distracted = "DISTRACTED"
    case speeding = "SPEEDING"
    case faceNotVisible = "FACE NOT VISIBLE"

    var prompt: String {
        switch self {
        case .drowsy:
            return """
            SAFETY ALERT: DROWSY.
            The monitoring system flagged possible drowsiness. Clearly mention that the person may be getting tired and recommend pulling over somewhere safe to rest. Speak naturally in no more than 1 short sentences.
            """

        case .distracted:
            return """
            SAFETY ALERT: DISTRACTED.
            The monitoring system flagged possible distracted driving. Clearly mention the distraction and encourage refocusing on the road. Do not ask a question. Speak naturally in no more than 1 short sentences.
            """

        case .speeding:
            return """
            SAFETY ALERT: SPEEDING.
            The vehicle's estimated speed exceeded the configured threshold. Clearly mention that the person is going too fast and encourage slowing down safely. Do not claim to know the posted speed limit. Speak naturally in no more than 1 short sentences.
            """

        case .faceNotVisible:
            return """
            SAFETY ALERT: FACE_NOT_VISIBLE.
            The monitoring system cannot see the driver's face, so attention monitoring may be limited. Explain this clearly and suggest adjusting the camera only when safely parked. Speak naturally in no more than 1 short sentences.
            """
        }
    }

    // Spoken if the on-device AI can't answer.
    // A safety warning must never depend on the AI working.
    var fallbackMessage: String {
        switch self {
        case .drowsy:
            return "You may be getting drowsy. Please pull over somewhere safe to rest."
        case .distracted:
            return "Distraction detected. Please bring your attention back to the road."
        case .speeding:
            return "You're going too fast. Please slow down."
        case .faceNotVisible:
            return "I can't see your face, so monitoring is limited."
        }
    }

}

// SafeDrive's brain: Apple's on-device language model (private, no internet).
@MainActor
final class AIService {

    private var session: LanguageModelSession?

    /*
     A temperature of 0.8 is a reasonable starting point for a friendly passenger that occasionally tells jokes.
     It gives you more control over creativity than relying on the framework's default.
     */
    
    // Controls how creative and how long the AI's replies are.
    private let options = GenerationOptions(
        temperature: 0.8, // // Higher values allow more varied responses, e.g. (0.2) = more predictable, 0.8= more varied
        maximumResponseTokens: 60 // Short answers = faster replies. ~100 tokens is about 3 sentences
    )

    // The AI's personality and rules. Written for being SPOKEN aloud.

    private let systemInstruction = """
        You are a friendly, mature, and witty AI passenger for teenage drivers.
        Sound like a caring older sibling, parent or a friend, not a chatbot or authority figure.

        Speak naturally, warmly, and casually, using everyday language.
        Be playful or lightly humorous when appropriate, but never force jokes.
        Avoid slang, lectures, robotic phrases, and repetitive warnings.

        Listen carefully and respond directly to what the driver says.
        Acknowledge concerns, handle disagreements thoughtfully, and
        adapt naturally when the conversation changes direction.
        Ask occasional short questions when they genuinely help.

        Respond in ONE natural sentence.
        Use a second short sentence only when essential.
        Never give long explanations, monologues, or multiple examples.

        Safety always comes first.
        Be calm but firm when the driver may be in danger.
        Never joke about an active safety risk or encourage unsafe driving.
        Never suggest conversation can replace rest or safe driving habits.
        Never invent detected alerts, speed limits, or surroundings.
    """


    // Defines the errors this service can report to the app.
    enum AIError: LocalizedError {
        case modelUnavailable(String)
        case generationFailed(String)
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .modelUnavailable(let reason): 
                return "On-device AI is unavailable: \(reason)"
            case .generationFailed(let details): 
                return "AI generation failed: \(details)"
            case .emptyResponse: 
                return "The on-device AI returned an empty response."
            }
        }
    }


    // Send a message and return the AI's spoken reply
    // isRetry prevents the app from repeatedly retrying the same failed request.
    func sendMessage(_ message: String, isRetry: Bool = false) async throws -> String {

        // Check that Apple Intelligence is available.
        if case .unavailable(let reason) =
            SystemLanguageModel.default.availability {
            throw AIError.modelUnavailable(String(describing: reason))
        }

        // Create a session on the first message.
        // The same session remembers the conversation.
        if session == nil {
            session = LanguageModelSession(
                instructions: systemInstruction
            )
        }
        
        // Get the session to use for this message.
        guard let currentSession = session else {
            throw AIError.modelUnavailable(
                "Could not create a session."
            )
        }
        
        do {
            // Ask AI to respond to user's message.
            let result = try await currentSession.respond(
                to: message,
                options: options
            )
            
            // Remove extra spaces and line breaks from AI's response.
            let answer = result.content.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            
            // Make sure the AI returned an actual response.
            guard !answer.isEmpty else {
                throw AIError.emptyResponse
            }
           
            print("ON-DEVICE AI RESPONSE:", answer)
            
            // Return the cleaned response to the calling code
            return answer

        } catch let error as LanguageModelSession.GenerationError {
            // Handle errors specifically related to AI response generation.
            switch error {

            // Long chats eventually fill the model's memory. Start fresh session and retry once.
            case .exceededContextWindowSize where !isRetry:
                self.session = nil
                return try await sendMessage(message, isRetry: true)

            // Apple's safety filter blocked the topic. Don't crash the chat; redirect.
            case .guardrailViolation(_), .refusal(_, _):
                return "Sorry, App's safety rules won't let me answer that. But let's continue to keep our focus on the road. Want to talk about something else?"

            default:
                throw AIError.generationFailed(error.localizedDescription)
            }

        } catch is CancellationError {
            print("AI CANCELLED: Task.isCancelled =", Task.isCancelled)
            throw CancellationError()

        } catch let error as AIError {
            print("AI SERVICE ERROR:", error)
            throw error

        } catch {
            print("AI UNEXPECTED ERROR:", type(of: error), error)
            throw AIError.generationFailed(error.localizedDescription)
        }
    }

    
    // Start a new AI conversation with the detected safety alert as context.
    func startConversation(for alert: SafetyAlert) {
        session = LanguageModelSession(
            instructions: """
            \(systemInstruction)
            The conversation started because Driver Monitoring System detected \(alert.rawValue).
            The driver has already received the warning.
            """
        )
    }
    
    
    // Forget the current conversation, set session nil
    func resetConversation() {
        session = nil
    }
}
