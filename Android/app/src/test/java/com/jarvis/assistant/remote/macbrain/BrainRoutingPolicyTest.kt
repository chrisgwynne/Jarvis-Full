package com.jarvis.assistant.remote.macbrain

import com.jarvis.assistant.remote.brain.BrainRoutingPolicy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * BrainRoutingPolicyTest — proves the local-first / Brain-assisted routing boundary.
 *
 * Rules under test (from [BrainRoutingPolicy]):
 *   A. Instant-command prefixes return null — Brain is NEVER called for these.
 *   B. Project signals  → "project"
 *   C. History signals  → "history"
 *   D. Memory signals   → "memory"
 *   E. Everything else  → null (local-only, no Brain fetch)
 *
 * The "local-first" guarantee: any transcript that returns null from [BrainRoutingPolicy.intentHint]
 * will NEVER incur a Brain network call regardless of feature-flag or circuit-breaker state.
 * These tests prove that guarantee holds for every category that must be instant.
 */
class BrainRoutingPolicyTest {

    // ── Rule A: Instant commands — Brain must never be contacted ──────────────

    @Test fun `volume up skips Brain`()    = assertLocal("volume up please")
    @Test fun `volume down skips Brain`()  = assertLocal("turn down the volume")
    @Test fun `mute skips Brain`()         = assertLocal("mute the phone")
    @Test fun `unmute skips Brain`()       = assertLocal("unmute")

    @Test fun `flashlight on skips Brain`()   = assertLocal("flashlight on")
    @Test fun `flashlight off skips Brain`()  = assertLocal("flashlight")
    @Test fun `torch on skips Brain`()        = assertLocal("torch")
    @Test fun `turn on flash skips Brain`()   = assertLocal("turn on flash")
    @Test fun `turn off flash skips Brain`()  = assertLocal("turn off flash")
    @Test fun `flash on skips Brain`()        = assertLocal("flash on")
    @Test fun `flash off skips Brain`()       = assertLocal("flash off")

    @Test fun `open app skips Brain`()    = assertLocal("open spotify")
    @Test fun `launch app skips Brain`()  = assertLocal("launch youtube")
    @Test fun `close app skips Brain`()   = assertLocal("close the app")

    @Test fun `play music skips Brain`()       = assertLocal("play some music")
    @Test fun `pause skips Brain`()            = assertLocal("pause")
    @Test fun `stop music skips Brain`()       = assertLocal("stop music")
    @Test fun `next song skips Brain`()        = assertLocal("next song")
    @Test fun `previous song skips Brain`()    = assertLocal("previous song")
    @Test fun `skip song skips Brain`()        = assertLocal("skip song")

    @Test fun `call skips Brain`()      = assertLocal("call mom")
    @Test fun `ring skips Brain`()      = assertLocal("ring dad")
    @Test fun `dial skips Brain`()      = assertLocal("dial 07712 345678")

    @Test fun `text message skips Brain`()     = assertLocal("text sarah I'll be late")
    @Test fun `message contact skips Brain`()  = assertLocal("message david what time are we meeting")
    @Test fun `send message skips Brain`()     = assertLocal("send john a message")

    @Test fun `take a photo skips Brain`()   = assertLocal("take a photo")
    @Test fun `take a selfie skips Brain`()  = assertLocal("take a selfie")
    @Test fun `screenshot skips Brain`()     = assertLocal("screenshot")

    @Test fun `set a timer skips Brain`()   = assertLocal("set a timer for 10 minutes")
    @Test fun `set timer skips Brain`()     = assertLocal("set timer 5 minutes")
    @Test fun `start a timer skips Brain`() = assertLocal("start a timer for 30 seconds")
    @Test fun `start timer skips Brain`()   = assertLocal("start timer")
    @Test fun `timer for skips Brain`()     = assertLocal("timer for 5 minutes")

    @Test fun `set an alarm skips Brain`() = assertLocal("set an alarm for 7am")
    @Test fun `set alarm skips Brain`()    = assertLocal("set alarm for 6:30am")
    @Test fun `alarm for skips Brain`()    = assertLocal("alarm for 6:30am")

    @Test fun `brightness skips Brain`()         = assertLocal("brightness 50 percent")
    @Test fun `screen rotation skips Brain`()    = assertLocal("screen rotation off")
    @Test fun `do not disturb skips Brain`()     = assertLocal("do not disturb")
    @Test fun `dnd on skips Brain`()             = assertLocal("dnd on")
    @Test fun `dnd off skips Brain`()            = assertLocal("dnd off")

    @Test fun `navigate to skips Brain`()    = assertLocal("navigate to the gym")
    @Test fun `directions to skips Brain`()  = assertLocal("directions to Heathrow")
    @Test fun `take me to skips Brain`()     = assertLocal("take me to King's Cross")

    // Home Assistant commands go through InstantCommandRouter locally and produce
    // no Brain signal — Brain is not called regardless.
    @Test fun `HA turn-on command skips Brain`()      = assertLocal("turn on the kitchen lights")
    @Test fun `HA turn-off command skips Brain`()     = assertLocal("switch off the lounge lamp")
    @Test fun `HA thermostat command skips Brain`()   = assertLocal("set the thermostat to 21 degrees")
    @Test fun `HA lock command skips Brain`()         = assertLocal("lock the front door")

    // ── Rule B: Project intent ────────────────────────────────────────────────

    @Test fun `what's broken → project`()         = assertBrain("project", "what's broken")
    @Test fun `what is broken → project`()        = assertBrain("project", "what is broken")
    @Test fun `github → project`()                = assertBrain("project", "any github updates today")
    @Test fun `pull request → project`()          = assertBrain("project", "show me open pull requests")
    @Test fun `open prs → project`()              = assertBrain("project", "are there open prs")
    @Test fun `what are we building → project`()  = assertBrain("project", "what are we building this sprint")
    @Test fun `what are we working on → project`()= assertBrain("project", "what are we working on")
    @Test fun `what's outstanding → project`()    = assertBrain("project", "what's outstanding")
    @Test fun `outstanding tasks → project`()     = assertBrain("project", "any outstanding tasks")
    @Test fun `known issues → project`()          = assertBrain("project", "any known issues")
    @Test fun `open issues → project`()           = assertBrain("project", "are there open issues")
    @Test fun `codebase → project`()              = assertBrain("project", "how is the codebase organised")
    @Test fun `the repo → project`()              = assertBrain("project", "check the repo")
    @Test fun `the branch → project`()            = assertBrain("project", "what's on the branch")
    @Test fun `what's next on → project`()        = assertBrain("project", "what's next on the roadmap")
    @Test fun `the project → project`()           = assertBrain("project", "what's the status of the project")

    // ── Rule C: History intent ────────────────────────────────────────────────

    @Test fun `what did we decide → history`()    = assertBrain("history", "what did we decide last time")
    @Test fun `what did we discuss → history`()   = assertBrain("history", "what did we discuss earlier")
    @Test fun `what did we agree → history`()     = assertBrain("history", "what did we agree on")
    @Test fun `we talked about → history`()       = assertBrain("history", "we talked about this before")
    @Test fun `we decided → history`()            = assertBrain("history", "we decided to do it this way")
    @Test fun `last time → history`()             = assertBrain("history", "what happened last time")
    @Test fun `last week → history`()             = assertBrain("history", "what did we do last week")
    @Test fun `you mentioned → history`()         = assertBrain("history", "you mentioned something about that")
    @Test fun `previously → history`()            = assertBrain("history", "previously you said the deadline was Friday")
    @Test fun `pick up where → history`()         = assertBrain("history", "let's pick up where we left off")
    @Test fun `remember when → history`()         = assertBrain("history", "remember when we first worked on this")
    @Test fun `continue where → history`()        = assertBrain("history", "continue where we left off")

    // ── Rule D: Memory intent ─────────────────────────────────────────────────

    @Test fun `remember that → memory`()             = assertBrain("memory", "remember that I prefer dark mode")
    @Test fun `don't forget → memory`()              = assertBrain("memory", "don't forget I like jazz")
    @Test fun `keep in mind → memory`()              = assertBrain("memory", "keep in mind I don't eat meat")
    @Test fun `do you remember → memory`()           = assertBrain("memory", "do you remember my dog's name")
    @Test fun `what do you remember → memory`()      = assertBrain("memory", "what do you remember about our last session")
    @Test fun `what do you know about me → memory`() = assertBrain("memory", "what do you know about me")
    @Test fun `what did i tell you → memory`()       = assertBrain("memory", "what did i tell you about my preferences")
    @Test fun `what did i say → memory`()            = assertBrain("memory", "what did i say earlier about the deadline")
    @Test fun `my preferences → memory`()            = assertBrain("memory", "show me my preferences")
    @Test fun `my settings → memory`()               = assertBrain("memory", "what are my settings")
    @Test fun `what's my name → memory`()            = assertBrain("memory", "what's my name again")
    @Test fun `what is my name → memory`()           = assertBrain("memory", "what is my name")
    @Test fun `have i told you → memory`()           = assertBrain("memory", "have i told you about this before")
    @Test fun `forget that → memory via remember`()  = assertBrain("memory", "what did i tell you to forget")

    // ── Rule E: Default — unrecognised returns null ───────────────────────────

    @Test fun `general chat returns null`()  = assertLocal("what's the weather like today")
    @Test fun `joke request returns null`()  = assertLocal("tell me a joke")
    @Test fun `time query returns null`()    = assertLocal("what time is it")
    @Test fun `maths returns null`()         = assertLocal("what's 7 times 8")
    @Test fun `news returns null`()          = assertLocal("any news today")
    @Test fun `short greeting returns null`() = assertLocal("hey jarvis")
    @Test fun `geography query returns null`() = assertLocal("what's the capital of France")

    // ── Priority: project wins over memory when both match ───────────────────

    @Test
    fun `project signal beats memory signal when both are present`() {
        // "what did i tell you about the github issue" has both:
        //   memory: "what did i tell you"
        //   project: "github"
        // Project is checked first → "project" wins
        assertBrain("project", "what did i tell you about the github issue")
    }

    @Test
    fun `project signal beats history signal when both are present`() {
        // "last week's pull requests" has both:
        //   history: "last week"
        //   project: "pull request"
        // Project is checked first → "project"
        assertBrain("project", "show me last week's pull requests")
    }

    @Test
    fun `history signal beats memory signal when both are present`() {
        // "what did we decide about my preferences" has both:
        //   history: "what did we"
        //   memory:  "my preferences"
        // History is checked before memory → "history"
        assertBrain("history", "what did we decide about my preferences")
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private fun hint(transcript: String): String? =
        BrainRoutingPolicy.intentHint(transcript)

    /** Asserts that [transcript] returns null — Brain is skipped. */
    private fun assertLocal(transcript: String) =
        assertNull("Brain must be skipped for: \"$transcript\"", hint(transcript))

    /** Asserts that [transcript] returns the expected [intent] hint. */
    private fun assertBrain(intent: String, transcript: String) =
        assertEquals("Expected intent \"$intent\" for: \"$transcript\"", intent, hint(transcript))
}
