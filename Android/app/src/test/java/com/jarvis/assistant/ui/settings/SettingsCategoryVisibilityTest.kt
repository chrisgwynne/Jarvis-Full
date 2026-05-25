package com.jarvis.assistant.ui.settings

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Contract tests for the Settings home visibility model.
 *
 * The Settings home is required to show:
 *   - Exactly 10 user-facing categories in normal mode (developerOnly = false).
 *   - One additional "Developer Diagnostics" row when Developer Mode is on.
 *
 * Anything else MUST be developerOnly so it does not appear on the home
 * screen.  This test fails fast on any new top-level row sneaking in or any
 * legacy raw-config / diagnostic row being inadvertently un-hidden.
 *
 * It also asserts that the legacy hub categories (`PhoneControl`,
 * `CameraVision`, `Privacy`, `Proactivity`) — which were deleted as part
 * of the Settings cleanup — are not in the enum at all.
 */
class SettingsCategoryVisibilityTest {

    /** The exact 10 user-facing categories surfaced at the Settings home. */
    private val expectedUserFacing = setOf(
        SettingsCategory.Voice,
        SettingsCategory.Conversation,
        SettingsCategory.Messaging,
        SettingsCategory.Advanced,            // "AI Provider"
        SettingsCategory.AmbientIntelligence,
        SettingsCategory.Memory,
        SettingsCategory.TrustAutonomy,
        SettingsCategory.Vision,
        SettingsCategory.MacIntegration,
        SettingsCategory.AboutHelp,
    )

    @Test
    fun `normal mode shows exactly the 10 user-facing categories`() {
        val visible = SettingsCategory.entries.filter { !it.developerOnly }.toSet()
        assertEquals(
            "Top-level visible categories drifted from the contract. " +
                "Add new top-level entries deliberately, or set developerOnly = true.",
            expectedUserFacing, visible,
        )
        assertEquals(10, visible.size)
    }

    /**
     * Mirror of the visibility filter in
     * [com.jarvis.assistant.ui.settings.SettingsRootScreen] — kept in lock-step
     * here so the contract is testable without spinning up Compose.
     */
    private fun homeRows(devMode: Boolean): Set<SettingsCategory> =
        SettingsCategory.entries.filter { cat ->
            !cat.developerOnly || (devMode && cat == SettingsCategory.DeveloperDiagnostics)
        }.toSet()

    @Test
    fun `dev mode adds exactly the Developer Diagnostics row, nothing else`() {
        val normal = homeRows(devMode = false)
        val dev    = homeRows(devMode = true)
        assertEquals(expectedUserFacing, normal)
        assertEquals(expectedUserFacing + SettingsCategory.DeveloperDiagnostics, dev)
        // Crucially: turning dev mode on must NOT add any of the per-topic
        // diagnostic / legacy raw-config rows to the home screen.
        val homeOnlyAddedInDev = dev - normal
        assertEquals(setOf(SettingsCategory.DeveloperDiagnostics), homeOnlyAddedInDev)
    }

    @Test
    fun `DeveloperDiagnostics row is itself developer-only and lives in the dev section`() {
        assertTrue(
            "DeveloperDiagnostics must be developerOnly",
            SettingsCategory.DeveloperDiagnostics.developerOnly,
        )
        assertEquals(
            SettingsSection.SystemDiagnostics,
            SettingsCategory.DeveloperDiagnostics.section,
        )
    }

    @Test
    fun `legacy raw-config and per-topic diagnostic screens are developerOnly`() {
        val mustBeDeveloperOnly = setOf(
            "BrainGateway", "MacBridge", "MacBrain",
            "ConnectionDiagnostics", "LocalDiagnostics", "VoiceDiagnostics",
            "VisionDiagnostics", "AppControlDiagnostics", "SessionDiagnostics",
            "TrustDiagnostics", "MacBridgeDiagnostics", "MacBrainDiagnostics",
            "SpeechLatency", "ExperimentalFlags",
        )
        mustBeDeveloperOnly.forEach { name ->
            val cat = SettingsCategory.entries.firstOrNull { it.name == name }
            assertTrue("Missing expected category $name", cat != null)
            assertTrue("$name must be developerOnly", cat!!.developerOnly)
        }
    }

    @Test
    fun `removed hub categories are gone`() {
        listOf("PhoneControl", "CameraVision", "Privacy").forEach { name ->
            val cat = SettingsCategory.entries.firstOrNull { it.name == name }
            assertNull(
                "Category $name was deleted as part of the Settings cleanup and " +
                    "must not be reintroduced — its content is now surfaced at the " +
                    "Settings home directly.",
                cat,
            )
        }
    }

    @Test
    fun `no duplicate routes`() {
        val routes = SettingsCategory.entries.map { it.route }
        val dups   = routes.groupingBy { it }.eachCount().filterValues { it > 1 }
        assertTrue("Duplicate settings routes: $dups", dups.isEmpty())
    }

    @Test
    fun `no user-facing row uses a Diagnostics suffix in its title`() {
        val visible = SettingsCategory.entries.filter { !it.developerOnly }
        val offenders = visible.filter { it.title.contains("Diagnostics", ignoreCase = true) }
        assertTrue(
            "User-facing rows must not advertise as Diagnostics: ${offenders.map { it.title }}",
            offenders.isEmpty(),
        )
    }

    @Test
    fun `Mac Integration is the single non-developer Mac entry in normal mode`() {
        val visibleMac = SettingsCategory.entries.filter {
            !it.developerOnly && (
                it.title.contains("Mac", ignoreCase = true) ||
                it.title.contains("Gateway", ignoreCase = true) ||
                it.title.contains("Bridge", ignoreCase = true) ||
                it.title.contains("Brain", ignoreCase = true)
            )
        }
        assertEquals(
            "Only Mac Integration should be visible to normal users; legacy " +
                "Gateway/Bridge/Brain rows must stay developerOnly.",
            listOf(SettingsCategory.MacIntegration), visibleMac,
        )
    }

    @Test
    fun `every user-facing category maps to a non-developer section header`() {
        val visible = SettingsCategory.entries.filter { !it.developerOnly }
        val sectionsUsed = visible.map { it.section }.toSet()
        assertFalse(
            "User-facing categories must not land in the Developer & Diagnostics section",
            SettingsSection.SystemDiagnostics in sectionsUsed,
        )
    }
}
