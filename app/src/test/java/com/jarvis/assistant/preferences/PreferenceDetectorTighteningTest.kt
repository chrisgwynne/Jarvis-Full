package com.jarvis.assistant.preferences

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests for the tightened "tell/give/show me" preference pattern.
 *
 * Pre-fix: "Give me directions to Sainsbury's" matched the broad preference
 * regex and produced "Got it. I'll adjust Maps & Navigation responses."
 *
 * Post-fix: only utterances carrying an explicit preference qualifier
 * (just / only / always / never / brief / short / detailed / full / complete)
 * count as preferences.
 */
class PreferenceDetectorTighteningTest {

    // ── Must NOT be classed as preferences (regression fixes) ───────────────

    @Test fun `give me directions to Sainsburys is not a preference`() {
        assertFalse(PreferenceDetector.isPreference("Give me directions to Sainsbury's"))
    }

    @Test fun `give me the route to Tesco is not a preference`() {
        assertFalse(PreferenceDetector.isPreference("Give me the route to Tesco"))
    }

    @Test fun `tell me the time is not a preference`() {
        assertFalse(PreferenceDetector.isPreference("Tell me the time"))
    }

    @Test fun `show me my calendar is not a preference`() {
        assertFalse(PreferenceDetector.isPreference("Show me my calendar"))
    }

    @Test fun `give me a weather summary is not a preference`() {
        assertFalse(PreferenceDetector.isPreference("Give me a weather summary"))
    }

    // ── Still detected as preferences (must keep working) ───────────────────

    @Test fun `tell me just the temperature is a preference`() {
        assertTrue(PreferenceDetector.isPreference("Tell me just the temperature"))
    }

    @Test fun `give me only the high and low is a preference`() {
        assertTrue(PreferenceDetector.isPreference("Give me only the high and low"))
    }

    @Test fun `show me always the location is a preference`() {
        assertTrue(PreferenceDetector.isPreference("Show me always the location"))
    }

    @Test fun `tell me the brief version is a preference`() {
        assertTrue(PreferenceDetector.isPreference("Tell me the brief version"))
    }

    @Test fun `give me the detailed view is an override not a stored preference`() {
        // "Give me the (full|complete|detailed|everything|all) ..." is a
        // ONE-OFF override per PreferenceDetector design — isPreference()
        // returns false for those.  This is correct behaviour: the response
        // should be detailed THIS time, not for every future query.
        assertFalse(PreferenceDetector.isPreference("Give me the detailed view"))
        assertTrue(PreferenceDetector.isOverride("Give me the detailed view"))
    }

    @Test fun `i prefer brief weather is still a preference`() {
        assertTrue(PreferenceDetector.isPreference("I prefer brief weather"))
    }

    @Test fun `from now on keep it short is still a preference`() {
        assertTrue(PreferenceDetector.isPreference("from now on keep it short"))
    }
}
