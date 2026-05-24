package com.jarvis.assistant.remote.macbrain

/**
 * FakeMacBrainClient — no-op implementation for tests and feature-disabled state.
 *
 * Always returns null — Android proceeds with local context only.
 * Inject this in unit tests that exercise [VoicePipeline] without a live Brain server.
 *
 * Optionally supply a [stubbedResponse] to make specific test scenarios return
 * controlled Brain context without standing up an HTTP server.
 */
class FakeMacBrainClient(
    private val stubbedResponse: BrainContextResponse? = null,
) : MacBrainClient {

    override suspend fun fetchContext(request: BrainContextRequest): BrainContextResponse? =
        stubbedResponse

    override suspend fun health(): Boolean = stubbedResponse != null
}
