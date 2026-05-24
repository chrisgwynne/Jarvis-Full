import Foundation

// MARK: - Thinking-block stripper

private extension String {
    /// Removes all `<thinking>…</thinking>` and `<think>…</think>` blocks that
    /// reasoning-mode LLMs (DeepSeek-R1, QwQ, some MiniMax variants) prepend to
    /// their answers.  The tags are matched case-insensitively and may span
    /// multiple lines.  Nested tags of the same kind are not supported (models
    /// don't produce them in practice).
    func strippingThinkingBlocks() -> String {
        var result = self
        for tag in ["thinking", "think"] {
            let open  = "<\(tag)>"
            let close = "</\(tag)>"
            // Iterate so multiple consecutive blocks are all removed.
            while let startRange = result.range(of: open,  options: .caseInsensitive),
                  let endRange   = result.range(of: close, options: .caseInsensitive,
                                                range: startRange.upperBound ..< result.endIndex) {
                let removeRange = startRange.lowerBound ... endRange.upperBound
                result.removeSubrange(removeRange)
            }
        }
        return result
    }
}

/// OpenAI-compatible Chat Completions client.
///
/// Used by `LlamaCppProvider` (truly OpenAI-compatible) and
/// `MiniMaxProvider` (close enough — the v2 chat-completion endpoint
/// accepts the same `{model, messages, temperature}` body shape).
/// Differences between MiniMax and OpenAI (auth header, optional
/// per-vendor fields) are absorbed by the `extraBodyFields` parameter
/// and the configurable `Authorization` header value.
struct OpenAIChatClient {

    /// Fully-qualified chat completions URL.
    /// llama.cpp default: http://localhost:8080/v1/chat/completions
    /// MiniMax default:   https://api.minimax.io/v1/chat/completions
    let endpoint: URL
    /// "Bearer <token>" for MiniMax, can be nil for llama.cpp.
    let authorizationHeader: String?
    let model: String

    // MARK: - Retry policy

    /// Total attempts including the first.  3 means: try once, retry twice
    /// (at 250 ms then 500 ms).  Tuned to be invisible on transient blips
    /// while never adding more than ~1 s of latency in the worst-retry case.
    private static let maxAttempts = 3
    /// First-retry backoff in milliseconds; subsequent retries double it.
    private static let baseBackoffMs = 250

    // MARK: - Shared session

    /// Reusable session configured for keep-alive and reduced connection overhead.
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = 4
        cfg.timeoutIntervalForRequest = 25
        cfg.timeoutIntervalForResource = 60
        return URLSession(configuration: cfg)
    }()

    func complete(systemPrompt: String,
                  userPrompt: String,
                  contextSummary: String?,
                  temperature: Double,
                  maxTokens: Int,
                  responseFormat: LLMRequest.ResponseFormat,
                  timeoutSeconds: TimeInterval,
                  imageData: Data? = nil,
                  extraBodyFields: [String: Any] = [:]) async throws
                  -> (text: String, raw: [String: Any]) {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let auth = authorizationHeader, !auth.isEmpty {
            req.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = timeoutSeconds

        // System messages are always plain strings.
        var messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt]
        ]
        if let ctx = contextSummary, !ctx.isEmpty {
            messages.append(["role": "system",
                             "content": "Context:\n\(ctx)"])
        }

        // User message: plain string for text-only, content array for vision.
        if let jpeg = imageData {
            let b64 = jpeg.base64EncodedString()
            let contentArray: [[String: Any]] = [
                ["type": "text", "text": userPrompt],
                ["type": "image_url",
                 "image_url": ["url": "data:image/jpeg;base64,\(b64)"]]
            ]
            messages.append(["role": "user", "content": contentArray])
        } else {
            messages.append(["role": "user", "content": userPrompt])
        }

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": temperature,
            "max_tokens": maxTokens,
            "stream": false
        ]
        if responseFormat == .json {
            // Both vendors accept this when their model supports it.
            // Servers that don't recognise it just ignore the key.
            body["response_format"] = ["type": "json_object"]
        }
        for (k, v) in extraBodyFields { body[k] = v }

        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        // ── Send with retry/backoff ──────────────────────────────────────────
        return try await sendWithRetry(req: req)
    }

    /// One full send + parse cycle.  Throws an `LLMError` typed so the
    /// retry wrapper can decide whether to retry.
    private func performOnce(_ req: URLRequest) async throws -> (text: String, raw: [String: Any]) {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await Self.session.data(for: req)
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw LLMError.timeout
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw LLMError.cancelled
        } catch {
            throw LLMError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.network("Non-HTTP response")
        }
        if http.statusCode == 429 { throw LLMError.rateLimited }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.http(http.statusCode, body)
        }

        guard let json = try JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            throw LLMError.decode("Top-level JSON not an object")
        }
        // Drill into OpenAI / MiniMax shape: choices[0].message.content
        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            // Some MiniMax responses use `reply` at top level — handle that.
            if let reply = json["reply"] as? String {
                return (reply, json)
            }
            throw LLMError.decode("Missing choices[0].message.content")
        }
        // Strip chain-of-thought reasoning blocks that some models (DeepSeek,
        // QwQ, certain MiniMax variants) emit before their final answer.
        // These tags must never reach TTS or the UI.
        let trimmed = content
            .strippingThinkingBlocks()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LLMError.empty }
        return (trimmed, json)
    }

    /// Drives up to `maxAttempts` total attempts at `performOnce`, with
    /// exponential backoff between retryable failures.  Does **not** retry
    /// 4xx errors (those signal a client problem that won't fix itself) or
    /// caller-cancellation.  Logs attempt count without leaking prompts.
    private func sendWithRetry(req: URLRequest) async throws -> (text: String, raw: [String: Any]) {
        var lastError: LLMError = .empty
        for attempt in 1...Self.maxAttempts {
            // Honor outer Task cancellation immediately.
            if Task.isCancelled { throw LLMError.cancelled }
            do {
                let result = try await performOnce(req)
                if attempt > 1 {
                    Log.app.info("llm_request_recovered_after_retry attempts=\(attempt) endpoint_host=\(req.url?.host ?? "?", privacy: .public)")
                }
                return result
            } catch let err as LLMError {
                lastError = err
                let retryable = Self.shouldRetry(error: err)
                if !retryable || attempt == Self.maxAttempts {
                    Log.app.warning("llm_request_failed attempts=\(attempt) retryable=\(retryable) endpoint_host=\(req.url?.host ?? "?", privacy: .public) error=\(err.errorDescription ?? "unknown", privacy: .public)")
                    throw err
                }
                let delayMs = Self.baseBackoffMs * Int(pow(2.0, Double(attempt - 1)))
                Log.app.info("llm_retry attempt=\(attempt) next_delay_ms=\(delayMs) endpoint_host=\(req.url?.host ?? "?", privacy: .public) reason=\(err.errorDescription ?? "unknown", privacy: .public)")
                try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            } catch {
                // Non-LLMError surface immediately — never retried.
                throw error
            }
        }
        // Unreachable in practice; loop always returns or throws.  Defensive.
        throw lastError
    }

    /// Classification of LLMError → retry decision.
    /// **Retry**: transient transport/server failures.
    /// **Do not retry**: 4xx client errors, decode failures, empty body,
    /// caller cancellation — these won't fix themselves with another attempt.
    ///
    /// Exposed at `internal` access so `@testable import` can verify the
    /// classification table without spinning up a real HTTP stack.
    static func shouldRetry(error: LLMError) -> Bool {
        switch error {
        case .rateLimited:        return true   // 429 — short backoff helps
        case .timeout:            return true   // transient
        case .network:            return true   // transient transport blip
        case .http(let code, _):
            // Only retry transient 5xx / gateway timeouts.
            return code == 500 || code == 502 || code == 503 || code == 504
        case .decode, .empty, .cancelled,
             .notConfigured, .providerDisabled:
            return false
        }
    }

    // MARK: - Vision completion with one or two images

    /// Like `complete()` but always sends the user message as a content array
    /// containing text plus one or two JPEG images (primary frame + optional ROI crop).
    ///
    /// Used by `MiniMaxVisionProvider` to send the full camera frame alongside an
    /// optional zoomed face/hand crop produced by `VisionROIExtractor`.
    ///
    /// The `responseFormat` is always `.text` — callers embed the JSON schema
    /// instruction inside the system prompt and parse the response themselves,
    /// so we never send `response_format: json_object` here.
    func completeWithVisionImages(
        systemPrompt:   String,
        userPrompt:     String,
        contextSummary: String?,
        temperature:    Double,
        maxTokens:      Int,
        timeoutSeconds: TimeInterval,
        primaryImage:   Data,
        roiImage:       Data?
    ) async throws -> (text: String, raw: [String: Any]) {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let auth = authorizationHeader, !auth.isEmpty {
            req.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = timeoutSeconds

        var messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt]
        ]
        if let ctx = contextSummary, !ctx.isEmpty {
            messages.append(["role": "system", "content": "Context:\n\(ctx)"])
        }

        // Build content array: text prompt + primary image + optional ROI crop.
        var contentArray: [[String: Any]] = [
            ["type": "text", "text": userPrompt],
            ["type": "image_url",
             "image_url": ["url": "data:image/jpeg;base64,\(primaryImage.base64EncodedString())"]]
        ]
        if let roi = roiImage {
            contentArray.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(roi.base64EncodedString())"]
            ])
        }
        messages.append(["role": "user", "content": contentArray])

        let body: [String: Any] = [
            "model":       model,
            "messages":    messages,
            "temperature": temperature,
            "max_tokens":  maxTokens,
            "stream":      false
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        return try await sendWithRetry(req: req)
    }

    // MARK: - Streaming completion (SSE / Server-Sent Events)

    /// Returns an `AsyncThrowingStream` that yields text delta chunks as they
    /// arrive from the SSE stream. Each yield is a raw content string fragment.
    /// The stream ends when `[DONE]` is received or the connection closes.
    ///
    /// Only use this for free-text responses — intent classification JSON
    /// requires the full payload and should use `complete()` instead.
    func streamComplete(
        systemPrompt:   String,
        userPrompt:     String,
        contextSummary: String?,
        temperature:    Double,
        maxTokens:      Int,
        timeoutSeconds: TimeInterval
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var req = URLRequest(url: endpoint)
                    req.httpMethod  = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if let auth = authorizationHeader, !auth.isEmpty {
                        req.setValue(auth, forHTTPHeaderField: "Authorization")
                    }
                    req.timeoutInterval = timeoutSeconds

                    var messages: [[String: String]] = [
                        ["role": "system", "content": systemPrompt]
                    ]
                    if let ctx = contextSummary, !ctx.isEmpty {
                        messages.append(["role": "system",
                                         "content": "Context:\n\(ctx)"])
                    }
                    messages.append(["role": "user", "content": userPrompt])

                    let body: [String: Any] = [
                        "model":       model,
                        "messages":    messages,
                        "temperature": temperature,
                        "max_tokens":  maxTokens,
                        "stream":      true
                    ]
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await Self.session.bytes(for: req)
                    if let http = response as? HTTPURLResponse,
                       !(200..<300).contains(http.statusCode) {
                        throw LLMError.http(http.statusCode, "Streaming HTTP error")
                    }

                    // Parse SSE lines
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }
                        guard let data   = payload.data(using: .utf8),
                              let json   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let delta   = choices.first?["delta"] as? [String: Any],
                              let chunk   = delta["content"] as? String,
                              !chunk.isEmpty
                        else { continue }
                        continuation.yield(chunk)
                    }
                    continuation.finish()

                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
