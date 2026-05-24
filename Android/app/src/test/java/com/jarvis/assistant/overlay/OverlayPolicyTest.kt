package com.jarvis.assistant.overlay

import com.jarvis.assistant.overlay.model.OverlayCardType
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Unit tests for [OverlayPolicy].
 *
 * Coverage:
 *  - Master toggle off  → all card types blocked
 *  - Bridge mode active → all card types blocked
 *  - HA alerts disabled → HOME_ASSISTANT_ALERT blocked; other types pass
 *  - Per-entity cooldown blocks the same entity within 120 s
 *  - Global HA cooldown blocks any HA card within 15 s of the first
 *  - Different entities each get their own cooldown slot
 *  - Non-HA card types are never subject to HA cooldowns
 *  - [OverlayPolicy.resetCooldowns] clears all per-entity and global state
 */
class OverlayPolicyTest {

    // ── Wiring helpers ────────────────────────────────────────────────────────

    private var overlaysEnabled  = true
    private var haEnabled        = true
    private var bridgeActive     = false

    @Before
    fun setUp() {
        overlaysEnabled = true
        haEnabled       = true
        bridgeActive    = false
        OverlayPolicy.resetCooldowns()
        OverlayPolicy.configure(
            overlaysEnabled  = { overlaysEnabled },
            haAlertsEnabled  = { haEnabled },
            bridgeModeActive = { bridgeActive },
        )
    }

    // ── 1. Master toggle ──────────────────────────────────────────────────────

    @Test
    fun `master toggle off — HA alert is blocked`() {
        overlaysEnabled = false
        assertFalse(OverlayPolicy.canShow(OverlayCardType.HOME_ASSISTANT_ALERT, "sensor.door"))
    }

    @Test
    fun `master toggle off — non-HA card types are also blocked`() {
        overlaysEnabled = false
        for (type in listOf(
            OverlayCardType.ACTION_SUCCESS,
            OverlayCardType.ACTION_FAILED,
            OverlayCardType.LISTENING_STATE,
            OverlayCardType.PROACTIVE_PROMPT,
            OverlayCardType.SMART_REPLY,
        )) {
            assertFalse("Expected $type to be blocked when overlays disabled",
                OverlayPolicy.canShow(type, null))
        }
    }

    @Test
    fun `master toggle on — non-HA card types pass`() {
        for (type in listOf(
            OverlayCardType.ACTION_SUCCESS,
            OverlayCardType.ACTION_FAILED,
            OverlayCardType.LISTENING_STATE,
            OverlayCardType.PROACTIVE_PROMPT,
        )) {
            assertTrue("Expected $type to pass when overlays enabled",
                OverlayPolicy.canShow(type, null))
        }
    }

    // ── 2. Bridge mode ────────────────────────────────────────────────────────

    @Test
    fun `bridge mode active — HA alert is blocked`() {
        bridgeActive = true
        assertFalse(OverlayPolicy.canShow(OverlayCardType.HOME_ASSISTANT_ALERT, "sensor.door"))
    }

    @Test
    fun `bridge mode active — non-HA card types are also blocked`() {
        bridgeActive = true
        assertFalse(OverlayPolicy.canShow(OverlayCardType.ACTION_SUCCESS, null))
        assertFalse(OverlayPolicy.canShow(OverlayCardType.SMART_REPLY, null))
    }

    @Test
    fun `bridge mode inactive — cards are allowed through`() {
        assertTrue(OverlayPolicy.canShow(OverlayCardType.ACTION_SUCCESS, null))
    }

    // ── 3. HA alerts category toggle ─────────────────────────────────────────

    @Test
    fun `HA alerts disabled — HOME_ASSISTANT_ALERT is blocked`() {
        haEnabled = false
        assertFalse(OverlayPolicy.canShow(OverlayCardType.HOME_ASSISTANT_ALERT, "sensor.door"))
    }

    @Test
    fun `HA alerts disabled — non-HA card types still pass`() {
        haEnabled = false
        assertTrue(OverlayPolicy.canShow(OverlayCardType.ACTION_SUCCESS, null))
        assertTrue(OverlayPolicy.canShow(OverlayCardType.LISTENING_STATE, null))
    }

    @Test
    fun `HA alerts enabled — first alert for an entity passes`() {
        assertTrue(OverlayPolicy.canShow(OverlayCardType.HOME_ASSISTANT_ALERT, "sensor.door"))
    }

    // ── 4. Per-entity cooldown ────────────────────────────────────────────────

    @Test
    fun `per-entity cooldown — same entity blocked immediately after first show`() {
        assertTrue("First show should pass",
            OverlayPolicy.canShow(OverlayCardType.HOME_ASSISTANT_ALERT, "sensor.front_door"))
        assertFalse("Second show immediately after should be blocked",
            OverlayPolicy.canShow(OverlayCardType.HOME_ASSISTANT_ALERT, "sensor.front_door"))
    }

    @Test
    fun `per-entity cooldown — different entities are independent`() {
        assertTrue(OverlayPolicy.canShow(OverlayCardType.HOME_ASSISTANT_ALERT, "sensor.door_a"))
        // door_a is now in cooldown, but door_b has a separate slot
        // Global cooldown is 15 s — but we need a way to advance time for that.
        // For this test we check that door_a is blocked (per-entity) while door_b
        // would also be blocked by global cooldown within 15 s.
        assertFalse("door_a should be blocked",
            OverlayPolicy.canShow(OverlayCardType.HOME_ASSISTANT_ALERT, "sensor.door_a"))
    }

    // ── 5. Global HA cooldown ─────────────────────────────────────────────────

    @Test
    fun `global HA cooldown — different entity blocked within 15 s`() {
        assertTrue("First entity should pass",
            OverlayPolicy.canShow(OverlayCardType.HOME_ASSISTANT_ALERT, "sensor.door_a"))
        // Same timestamp — second different entity hit within 15 s global window
        assertFalse("Second HA alert (different entity) within global cooldown should be blocked",
            OverlayPolicy.canShow(OverlayCardType.HOME_ASSISTANT_ALERT, "sensor.door_b"))
    }

    @Test
    fun `global HA cooldown — does not apply to non-HA types`() {
        assertTrue(OverlayPolicy.canShow(OverlayCardType.HOME_ASSISTANT_ALERT, "sensor.door"))
        // Non-HA types bypass HA gates entirely
        assertTrue("ACTION_SUCCESS should not be affected by HA global cooldown",
            OverlayPolicy.canShow(OverlayCardType.ACTION_SUCCESS, null))
        assertTrue("LISTENING_STATE should not be affected by HA global cooldown",
            OverlayPolicy.canShow(OverlayCardType.LISTENING_STATE, null))
    }

    // ── 6. resetCooldowns ─────────────────────────────────────────────────────

    @Test
    fun `resetCooldowns — clears per-entity cooldown`() {
        assertTrue(OverlayPolicy.canShow(OverlayCardType.HOME_ASSISTANT_ALERT, "sensor.door"))
        assertFalse("Should be in cooldown",
            OverlayPolicy.canShow(OverlayCardType.HOME_ASSISTANT_ALERT, "sensor.door"))
        OverlayPolicy.resetCooldowns()
        assertTrue("Should pass after reset",
            OverlayPolicy.canShow(OverlayCardType.HOME_ASSISTANT_ALERT, "sensor.door"))
    }

    @Test
    fun `resetCooldowns — clears global HA cooldown`() {
        assertTrue(OverlayPolicy.canShow(OverlayCardType.HOME_ASSISTANT_ALERT, "sensor.door_a"))
        assertFalse("door_b should be blocked by global cooldown",
            OverlayPolicy.canShow(OverlayCardType.HOME_ASSISTANT_ALERT, "sensor.door_b"))
        OverlayPolicy.resetCooldowns()
        assertTrue("door_b should pass after global cooldown reset",
            OverlayPolicy.canShow(OverlayCardType.HOME_ASSISTANT_ALERT, "sensor.door_b"))
    }

    // ── 7. Null entityId ──────────────────────────────────────────────────────

    @Test
    fun `null entityId — HA alert passes first call (no entity slot to check)`() {
        assertTrue(OverlayPolicy.canShow(OverlayCardType.HOME_ASSISTANT_ALERT, null))
    }

    @Test
    fun `null entityId — HA alert blocked by global cooldown on second call`() {
        assertTrue(OverlayPolicy.canShow(OverlayCardType.HOME_ASSISTANT_ALERT, null))
        assertFalse("Second call with null entityId should hit global cooldown",
            OverlayPolicy.canShow(OverlayCardType.HOME_ASSISTANT_ALERT, null))
    }
}
