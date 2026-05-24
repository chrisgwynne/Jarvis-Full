import SwiftUI
import EventKit

struct CalendarOverlayView: View {
    let calendarService: EventKitCalendarService

    private var events: [EKEvent] {
        calendarService.isAuthorized
            ? calendarService.eventsToday()
            : []
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "calendar")
                    .foregroundStyle(.blue)
                Text("Today")
                    .font(.headline)
                Spacer()
                Text(Date(), style: .date)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if !calendarService.isAuthorized {
                ContentUnavailableView(
                    "Calendar Access Needed",
                    systemImage: "calendar.badge.exclamationmark",
                    description: Text("Say 'grant calendar access' or check System Settings → Privacy → Calendars")
                )
                .padding()
            } else if events.isEmpty {
                ContentUnavailableView(
                    "No Events Today",
                    systemImage: "calendar",
                    description: Text("Your calendar is clear for today")
                )
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(events, id: \.eventIdentifier) { event in
                            EventRow(event: event)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .background(Color.clear)
    }
}

private struct EventRow: View {
    let event: EKEvent

    private var timeRange: String {
        let fmt = DateFormatter()
        fmt.dateStyle = .none
        fmt.timeStyle = .short
        let start = fmt.string(from: event.startDate)
        let end = fmt.string(from: event.endDate)
        return "\(start) – \(end)"
    }

    private var isNow: Bool {
        let now = Date()
        return event.startDate <= now && event.endDate >= now
    }

    private var isSoon: Bool {
        let minutesUntil = event.startDate.timeIntervalSinceNow / 60
        return minutesUntil > 0 && minutesUntil <= 15
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Time column
            VStack(alignment: .trailing, spacing: 2) {
                Text(timeRange)
                    .font(.caption)
                    .foregroundStyle(isNow ? .blue : .secondary)
                    .monospacedDigit()
            }
            .frame(width: 110, alignment: .trailing)

            // Color bar
            RoundedRectangle(cornerRadius: 2)
                .fill(isNow ? Color.blue : Color(cgColor: event.calendar.cgColor))
                .frame(width: 3)

            // Content
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(event.title ?? "Untitled")
                        .font(.subheadline)
                        .fontWeight(isNow ? .semibold : .regular)
                    if isNow {
                        Label("Now", systemImage: "circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                            .labelStyle(.titleAndIcon)
                    } else if isSoon {
                        Text("Soon")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                if let location = event.location, !location.isEmpty {
                    Label(location, systemImage: "location.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(event.calendar.title)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isNow ? Color.blue.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

#Preview {
    CalendarOverlayView(calendarService: EventKitCalendarService())
        .frame(width: 380, height: 480)
}
