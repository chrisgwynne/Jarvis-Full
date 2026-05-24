import Foundation

/// Lightweight Todoist REST API v2 client.
///
/// Authentication: bearer token from `Preferences.todoistAPIToken` (or Keychain).
/// Base URL: https://api.todoist.com/rest/v2/
///
/// Only the operations Jarvis needs are implemented:
///   - List active tasks (optionally filtered by project)
///   - Create a task
///   - Close (complete) a task by fuzzy title match
final class TodoistAPIClient {

    static let baseURL = "https://api.todoist.com/rest/v2"

    private let token: String
    private let session: URLSession

    init(token: String, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    // MARK: - Task model

    struct Task: Decodable, Identifiable {
        let id: String
        let content: String
        let description: String
        let priority: Int       // 1 (normal) – 4 (urgent)
        let due: Due?
        let is_completed: Bool

        struct Due: Decodable {
            let string: String?
            let date: String?
            let datetime: String?
        }

        var isOverdue: Bool {
            guard let dateStr = due?.date ?? due?.datetime else { return false }
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fmt2 = DateFormatter()
            fmt2.dateFormat = "yyyy-MM-dd"
            let date = fmt.date(from: dateStr) ?? fmt2.date(from: dateStr)
            guard let d = date else { return false }
            return d < Calendar.current.startOfDay(for: Date())
        }
    }

    // MARK: - API

    /// Fetch all active tasks (no filter = inbox + all projects).
    func getTasks() async throws -> [Task] {
        return try await get("/tasks")
    }

    /// Fetch tasks whose due date is in the past.
    func getOverdueTasks() async throws -> [Task] {
        let all = try await getTasks()
        return all.filter { $0.isOverdue }
    }

    /// Create a new task in the Inbox.
    @discardableResult
    func createTask(content: String, dueString: String? = nil) async throws -> Task {
        var body: [String: Any] = ["content": content]
        if let due = dueString { body["due_string"] = due }
        return try await post("/tasks", body: body)
    }

    /// Close (complete) a task by fuzzy title match. Returns true on success.
    func closeTask(matching phrase: String) async throws -> Bool {
        let tasks = try await getTasks()
        let needle = phrase.lowercased()
        let best = tasks.first { $0.content.lowercased().contains(needle) }
            ?? tasks.first { needle.contains($0.content.lowercased()) }
        guard let task = best else { return false }
        try await closeTask(id: task.id)
        return true
    }

    /// Close a task by its ID.
    func closeTask(id: String) async throws {
        try await postEmpty("/tasks/\(id)/close")
    }

    // MARK: - Spoken summaries

    func spokenSummary(tasks: [Task], max: Int = 3) -> String {
        let titles = tasks.prefix(max).map { $0.content }
        return titles.joined(separator: ", ")
    }

    // MARK: - HTTP

    private func get<T: Decodable>(_ path: String) async throws -> T {
        var req = URLRequest(url: URL(string: Self.baseURL + path)!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        try ensureOK(resp, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        var req = URLRequest(url: URL(string: Self.baseURL + path)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        try ensureOK(resp, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func postEmpty(_ path: String) async throws {
        var req = URLRequest(url: URL(string: Self.baseURL + path)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        try ensureOK(resp, data: data)
    }

    private func ensureOK(_ resp: URLResponse, data: Data) throws {
        guard let http = resp as? HTTPURLResponse else {
            throw JarvisError.http(-1, "No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data.prefix(256), encoding: .utf8) ?? ""
            throw JarvisError.http(http.statusCode, body)
        }
    }
}
