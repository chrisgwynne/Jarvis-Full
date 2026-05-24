import Foundation

/// Handles Calendar-domain intents previously inline in JarvisController.execute().
/// Extracted following the per-domain handler pattern — Sprint P decomposition.
@MainActor final class CalendarIntentHandler {

    private let calendarService: EventKitCalendarService
    private let renderer: ResponseRenderer

    var speak: (String) -> Void = { _ in }
    var setPendingContext: (PendingConversationContext) -> Void = { _ in }
    var currentTranscript: () -> String = { "" }

    init(calendarService: EventKitCalendarService, renderer: ResponseRenderer) {
        self.calendarService = calendarService
        self.renderer = renderer
    }

    /// Returns true if the intent was handled, false if it is not a Calendar intent.
    func handle(_ intent: Intent) async -> Bool {
        switch intent {
        case .showCalendar:
            guard calendarService.isAuthorized else {
                speak(renderer.render(ResponseKey.calendarNotConfigured)); return true
            }
            let (count, summary) = calendarService.spokenSummaryToday()
            if count == 0 {
                speak(renderer.render(ResponseKey.calendarNoEvents))
            } else {
                speak(renderer.render(ResponseKey.calendarToday,
                                      ["count": "\(count)",
                                       "count_label": count == 1 ? "event" : "events",
                                       "summary": summary]))
            }
            return true

        case .nextMeeting:
            guard calendarService.isAuthorized else {
                speak(renderer.render(ResponseKey.calendarNotConfigured)); return true
            }
            if let nextEvent = calendarService.nextEvent() {
                let timeFmt = DateFormatter()
                timeFmt.dateStyle = .none
                timeFmt.timeStyle = .short
                speak(renderer.render(ResponseKey.calendarNextMeeting,
                                      ["title": nextEvent.title ?? "a meeting",
                                       "time": timeFmt.string(from: nextEvent.startDate)]))
            } else {
                speak(renderer.render(ResponseKey.calendarNoUpcoming))
            }
            return true

        case .meetingsToday:
            guard calendarService.isAuthorized else {
                speak(renderer.render(ResponseKey.calendarNotConfigured)); return true
            }
            let (todayCount, todaySummary) = calendarService.spokenSummaryToday()
            if todayCount == 0 {
                speak(renderer.render(ResponseKey.calendarNoEvents))
            } else {
                speak(renderer.render(ResponseKey.calendarToday,
                                      ["count": "\(todayCount)",
                                       "count_label": todayCount == 1 ? "event" : "events",
                                       "summary": todaySummary]))
            }
            return true

        case .addReminder(let text):
            guard calendarService.isAuthorized else {
                speak(renderer.render(ResponseKey.calendarNotConfigured)); return true
            }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let question = "What would you like me to remind you about?"
                speak(question)
                setPendingContext(.make(
                    originalTranscript: currentTranscript(),
                    originalIntent: intent,
                    assistantQuestion: question,
                    responseType: .freeform,
                    onFreeform: .callLLMWithHistory
                ))
                return true
            }
            let ok = await calendarService.addReminder(text: text)
            speak(renderer.render(ok ? ResponseKey.calendarReminderAdded
                                     : ResponseKey.calendarReminderFailed,
                                  ["text": text]))
            return true

        default:
            return false
        }
    }
}
