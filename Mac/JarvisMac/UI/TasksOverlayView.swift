import SwiftUI

struct TasksOverlayView: View {
    let todoistClient: TodoistAPIClient?

    @State private var tasks: [TodoistAPIClient.Task] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.red)
                Text("Tasks")
                    .font(.headline)
                Spacer()
                if isLoading {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Button {
                        Task { await loadTasks() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if todoistClient == nil {
                ContentUnavailableView(
                    "Todoist Not Connected",
                    systemImage: "checkmark.circle",
                    description: Text("Add your Todoist API token in Settings")
                )
                .padding()
            } else if let error = errorMessage {
                ContentUnavailableView(
                    "Couldn't Load Tasks",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
                .padding()
            } else if tasks.isEmpty && !isLoading {
                ContentUnavailableView(
                    "No Tasks",
                    systemImage: "checkmark.circle.fill",
                    description: Text("You're all caught up!")
                )
                .padding()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        let overdue = tasks.filter(\.isOverdue)
                        let upcoming = tasks.filter { !$0.isOverdue }

                        if !overdue.isEmpty {
                            Section {
                                ForEach(overdue) { task in
                                    TaskRow(task: task, isOverdue: true)
                                }
                            } header: {
                                Text("OVERDUE")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.red)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 8)
                            }
                        }

                        if !upcoming.isEmpty {
                            Section {
                                ForEach(upcoming) { task in
                                    TaskRow(task: task, isOverdue: false)
                                }
                            } header: {
                                if !overdue.isEmpty {
                                    Text("UPCOMING")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 12)
                                        .padding(.top, 8)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        .background(Color.clear)
        .task { await loadTasks() }
    }

    private func loadTasks() async {
        guard let client = todoistClient else { return }
        isLoading = true
        errorMessage = nil
        do {
            tasks = try await client.getTasks()
            // Sort: overdue first, then by priority (4=urgent→1=normal in Todoist)
            tasks.sort {
                if $0.isOverdue != $1.isOverdue { return $0.isOverdue }
                return $0.priority > $1.priority
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct TaskRow: View {
    let task: TodoistAPIClient.Task
    let isOverdue: Bool

    private var priorityColor: Color {
        switch task.priority {
        case 4: return .red
        case 3: return .orange
        case 2: return .blue
        default: return .secondary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "circle")
                .foregroundStyle(isOverdue ? .red : priorityColor)
                .font(.system(size: 14))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.content)
                    .font(.subheadline)
                    .foregroundStyle(isOverdue ? .red : .primary)

                if let dueStr = task.due?.string ?? task.due?.date {
                    Label(dueStr, systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(isOverdue ? .red : .secondary)
                }

                if !task.description.isEmpty {
                    Text(task.description)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isOverdue ? Color.red.opacity(0.07) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

#Preview {
    TasksOverlayView(todoistClient: nil)
        .frame(width: 360, height: 500)
}
