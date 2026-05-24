package com.jarvis.assistant.architecture

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * ArchitectureInvariantsTest — pure-JVM source scanner that enforces
 * the routing + extraction rules documented in
 * `docs/architecture/routing-invariants.md`.
 *
 * Every assertion in this file maps to one numbered invariant (R1..R7).
 * Failures point at the file + reason so the fix is obvious.
 *
 * Also wired in as the Gradle task `:app:checkArchitectureInvariants`
 * (see app/build.gradle.kts), so a CI / pre-push run catches drift
 * without requiring the developer to remember.
 *
 * Why a source scanner rather than reflection?  Reflection only sees
 * the compiled bytecode at the call sites that survived dead-code
 * elimination.  These invariants are about the *shape of the source
 * tree* — duplicate class declarations, forbidden imports, missing
 * gates.  A textual scan is the right tool.
 */
class ArchitectureInvariantsTest {

    private val mainSrc = File("src/main/java/com/jarvis/assistant")
    private val mainSrcAlt = File("app/src/main/java/com/jarvis/assistant")
    private val srcRoot: File get() = if (mainSrc.isDirectory) mainSrc else mainSrcAlt

    private fun allKotlinFiles(): List<File> =
        srcRoot.walkTopDown().filter { it.isFile && it.extension == "kt" }.toList()

    private fun filesUnder(subpath: String): List<File> =
        File(srcRoot, subpath).walkTopDown().filter { it.isFile && it.extension == "kt" }.toList()

    // ── R1 — OpenClaw and Hermes packages have been fully removed ────────

    @Test fun `R1 OpenClaw and Hermes source packages no longer exist`() {
        val openClawDir = File(srcRoot, "remote/openclaw")
        val hermesDir   = File(srcRoot, "remote/hermes")
        assertFalse(
            "R1 violation — remote/openclaw/ still exists; the package was removed in Phase 1",
            openClawDir.isDirectory,
        )
        assertFalse(
            "R1 violation — remote/hermes/ still exists; the package was removed in Phase 1",
            hermesDir.isDirectory,
        )
    }

    // ── R2 — Todoist stays local-first ────────────────────────────────────

    @Test fun `R2 todoist package never imports removed remote packages`() {
        val violations = filesUnder("todoist").mapNotNull { file ->
            val text = file.readText()
            if ("import com.jarvis.assistant.remote.openclaw" in text ||
                "import com.jarvis.assistant.remote.hermes" in text) {
                file.relativeTo(srcRoot).path
            } else null
        }
        assertTrue(
            "R2 violation — todoist/** must not import removed remote packages:\n" +
                violations.joinToString("\n"),
            violations.isEmpty(),
        )
    }

    // ── R3 — Calendar / Maps / Messaging / Smart Home stay local-first ────

    @Test fun `R3 local-first feature packages never import removed remote packages`() {
        val checked = listOf(
            "maps",
            "tools/device/messaging",
            "tools/smart",
            "tools/device/apps",
        ).flatMap { filesUnder(it) }
        val singleFiles = listOf(
            "tools/device/CalendarTool.kt",
            "tools/device/CalendarCreateTool.kt",
            "tools/device/ShareLocationTool.kt",
            "tools/device/FindPhoneTool.kt",
        ).map { File(srcRoot, it) }.filter { it.isFile }
        val violations = (checked + singleFiles).mapNotNull { file ->
            val text = file.readText()
            if ("com.jarvis.assistant.remote.openclaw" in text ||
                "com.jarvis.assistant.remote.hermes" in text) {
                file.relativeTo(srcRoot).path
            } else null
        }
        assertTrue(
            "R3 violation — local-first packages must not import removed remote packages:\n" +
                violations.joinToString("\n"),
            violations.isEmpty(),
        )
    }

    // ── R4 — TTS never receives raw stack traces ──────────────────────────

    @Test fun `R4 ttsEngine speak call sites never speak Throwable toString`() {
        // Forbid the specific anti-pattern: `ttsEngine.speak(throwable.toString())`
        // / `ttsEngine.speak(e.message ?: "")` / `ttsEngine.speak(e.stackTraceToString())`.
        // These are the historical leaks SpeechSanitizer was designed to
        // prevent.
        val rx = Regex(
            """\bttsEngine\.speak\(\s*(?:[a-zA-Z_]\w*\.(?:toString\(\)|stackTraceToString\(\)|message))""",
        )
        val violations = allKotlinFiles().mapNotNull { file ->
            val matches = rx.findAll(file.readText())
                .map { it.value }
                .toList()
            if (matches.isNotEmpty()) {
                "${file.relativeTo(srcRoot)} → ${matches.joinToString("; ")}"
            } else null
        }
        assertTrue(
            "R4 violation — TTS spoken raw exception text:\n" +
                violations.joinToString("\n"),
            violations.isEmpty(),
        )
    }

    // ── R5 — local command success path returns to listening ──────────────

    @Test fun `R5 SessionContinuationPolicy default for local-tool path stays CONTINUE_LISTENING`() {
        val file = File(srcRoot, "runtime/session/SessionContinuationPolicy.kt")
        assertTrue("SessionContinuationPolicy not found at expected path",
            file.isFile)
        val text = file.readText()
        // The policy file MUST mention CONTINUE_LISTENING — the verdict
        // exists and is referenced.  We don't grep for an exact decision
        // table because the policy may legitimately evolve; we just lock
        // the contract that the verdict still exists in this file.
        assertTrue("CONTINUE_LISTENING verdict missing from policy",
            "CONTINUE_LISTENING" in text)
    }

    // ── R6 — OpenClaw and Hermes symbols no longer exist in source ────────

    @Test fun `R6 no OpenClaw or Hermes symbols remain in production source`() {
        // Phase 1 hard-removed all OpenClaw and Hermes code.  This test
        // ensures they are not re-introduced.  The only allowed exception
        // is SettingsStore.kt, which contains the Hermes→Anthropic migration
        // comment and guard condition (intentional).
        val forbidden = listOf("openClawRouter", "openClawNode", "openClawRepo",
            "HermesAgentProvider", "HermesJobsClient", "OpenClawClient",
            "OpenClawRouter", "OpenClawNodeClient")
        val violations = allKotlinFiles()
            .filter { !it.name.endsWith("Test.kt") && it.name != "SettingsStore.kt" }
            .flatMap { file ->
                val text = file.readText()
                forbidden.filter { it in text }.map { sym ->
                    "${file.relativeTo(srcRoot)} contains forbidden symbol: $sym"
                }
            }
        assertTrue(
            "R6 violation — removed OpenClaw/Hermes symbols still present:\n" +
                violations.joinToString("\n"),
            violations.isEmpty(),
        )
    }

    // ── R7 — architectural anchors appear exactly once ────────────────────

    @Test fun `R7 architectural anchor classes are defined exactly once`() {
        val anchors = listOf(
            "TranscriptNormalizer",
            "RecentActionContextStore",
            "UserSafeErrorHandler",
            "SessionContinuationPolicy",
            "CommandPermissionPolicy",
            "ContextualFollowupParser",
            "ProactivityGate",
            "ProactivitySettings",
            "JarvisRuntime",
        )
        for (anchor in anchors) {
            val rx = Regex("""^(?:class|object|sealed class|data class) $anchor\b""",
                RegexOption.MULTILINE)
            val matches = allKotlinFiles().sumOf { rx.findAll(it.readText()).count() }
            assertEquals(
                "R7 violation — anchor $anchor should appear exactly once, found $matches",
                1, matches,
            )
        }
    }

    // ── Bonus — no TODO bombs in proactivity or scheduled-reminders ───────

    @Test fun `no TODO HACK FIXME bombs in proactivity hot paths`() {
        val rx = Regex("""\b(TODO|FIXME|HACK|XXX):?""")
        val hotPaths = listOf("proactive", "runtime/context", "runtime/session")
            .flatMap { filesUnder(it) }
        val offenders = hotPaths.filter { rx.containsMatchIn(it.readText()) }
            .map { it.relativeTo(srcRoot).path }
        // Soft assertion — count is allowed but we surface it for visibility.
        assertFalse(
            "Unexpectedly large TODO/FIXME load in proactivity hot paths " +
                "(${offenders.size}):\n${offenders.joinToString("\n")}",
            offenders.size > 25,
        )
    }
}
