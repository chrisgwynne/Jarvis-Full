package com.jarvis.assistant.graph.templates

import com.jarvis.assistant.graph.model.ActionEdge
import com.jarvis.assistant.graph.model.ActionGraph
import com.jarvis.assistant.graph.model.ActionNode
import com.jarvis.assistant.graph.model.EdgeCondition
import com.jarvis.assistant.graph.model.NodeType

/**
 * GraphTemplates — the built-in deterministic action graphs shipped with Jarvis.
 *
 * ## Adding a new template
 *
 *   1. Define a new object that builds and exposes an [ActionGraph].
 *   2. Add it to [all] at the bottom of this file.
 *   3. Done — [ActionPlanBuilder] picks it up automatically.
 *
 * ## Node id conventions
 *
 *   Use `graphId/step` for clarity.  Ids must be unique within a graph but
 *   not across graphs.
 */
object GraphTemplates {

    // ── Helpers ───────────────────────────────────────────────────────────────

    private fun nodes(vararg nodes: ActionNode): Map<String, ActionNode> =
        nodes.associateBy { it.id }

    // ─────────────────────────────────────────────────────────────────────────
    // 1. leave_football
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * "Leaving for football" routine:
     *  1. CONFIRMATION — ready to head out?
     *  2. Navigate to the football ground (uses saved/geocoded destination).
     *  3. Open Spotify for the drive (optional).
     *  4. Turn heating off via smart home (optional).
     *
     * The navigate destination defaults to "football ground"; callers can
     * override it via [ActionPlanBuilder]'s paramExtractor.
     */
    val leaveFootball: ActionGraph = ActionGraph(
        id           = "leave_football",
        displayName  = "Leave for football",
        description  = "Open Maps navigation, put on some music, and turn the heating off.",
        triggerPhrases = listOf(
            "leaving for football",
            "leave for football",
            "heading to football",
            "heading to the match",
            "leave for the match",
            "off to football",
        ),
        nodes = nodes(
            ActionNode(
                id    = "confirm",
                type  = NodeType.CONFIRMATION,
                label = "Leave for football",
                overlayTitle = "Leave for football?",
                params = mapOf("message" to "I'll open Maps, put on Spotify, and turn the heating off."),
            ),
            ActionNode(
                id       = "navigate",
                type     = NodeType.TOOL_CALL,
                label    = "Navigate to football ground",
                toolName = "navigate",
                params   = mapOf("destination" to "football ground"),
                overlayTitle = "Opening Maps…",
            ),
            ActionNode(
                id       = "music",
                type     = NodeType.TOOL_CALL,
                label    = "Open Spotify",
                toolName = "open_app",
                params   = mapOf("app" to "Spotify"),
                optional = true,
                overlayTitle = "Starting music…",
            ),
            ActionNode(
                id       = "heating",
                type     = NodeType.TOOL_CALL,
                label    = "Turn heating off",
                toolName = "smart_home",
                params   = mapOf("entity_name" to "heating", "action" to "off"),
                optional = true,
                overlayTitle = "Turning heating off…",
            ),
        ),
        edges = listOf(
            ActionEdge("confirm",  "navigate", EdgeCondition.ON_CONFIRM_YES),
            ActionEdge("navigate", "music",    EdgeCondition.ALWAYS),
            ActionEdge("music",    "heating",  EdgeCondition.ALWAYS),
        ),
        startNodeId      = "confirm",
        confirmBeforeStart = false,
    )

    // ─────────────────────────────────────────────────────────────────────────
    // 2. bedtime
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * "Bedtime" routine:
     *  1. Dim bedroom lights (optional — skipped when HA not configured).
     *  2. Turn the TV off (optional).
     *  3. Enable Do Not Disturb.
     */
    val bedtime: ActionGraph = ActionGraph(
        id           = "bedtime",
        displayName  = "Bedtime",
        description  = "Dim the lights, turn the TV off, and enable Do Not Disturb.",
        triggerPhrases = listOf(
            "bedtime",
            "time for bed",
            "going to sleep",
            "heading to bed",
            "good night mode",
            "sleep mode",
        ),
        nodes = nodes(
            ActionNode(
                id       = "dim_lights",
                type     = NodeType.TOOL_CALL,
                label    = "Dim bedroom lights",
                toolName = "smart_home",
                params   = mapOf(
                    "entity_name" to "bedroom lights",
                    "action"      to "dim",
                    "value"       to "5",
                ),
                optional     = true,
                overlayTitle = "Dimming lights…",
            ),
            ActionNode(
                id       = "tv_off",
                type     = NodeType.TOOL_CALL,
                label    = "Turn TV off",
                toolName = "smart_home",
                params   = mapOf("entity_name" to "tv", "action" to "off"),
                optional     = true,
                overlayTitle = "Turning TV off…",
            ),
            ActionNode(
                id       = "dnd",
                type     = NodeType.TOOL_CALL,
                label    = "Enable Do Not Disturb",
                toolName = "dnd",
                params   = mapOf("on" to "true"),
                overlayTitle = "Silencing notifications…",
            ),
        ),
        edges = listOf(
            ActionEdge("dim_lights", "tv_off", EdgeCondition.ALWAYS),
            ActionEdge("tv_off",     "dnd",    EdgeCondition.ALWAYS),
        ),
        startNodeId = "dim_lights",
    )

    // ─────────────────────────────────────────────────────────────────────────
    // 3. going_out
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * "Going out" routine:
     *  1. CONFIRMATION — want me to take care of things?
     *  2. Check the front door lock status (optional).
     *  3. Turn the heating off (optional).
     *  4. Enable DND so calls don't distract while driving.
     */
    val goingOut: ActionGraph = ActionGraph(
        id           = "going_out",
        displayName  = "Going out",
        description  = "Check the door, turn the heating off, and silence notifications.",
        triggerPhrases = listOf(
            "going out",
            "heading out",
            "leaving the house",
            "leaving home",
            "i'm leaving",
            "i am leaving",
            "just leaving",
        ),
        nodes = nodes(
            ActionNode(
                id    = "confirm",
                type  = NodeType.CONFIRMATION,
                label = "Going out",
                overlayTitle = "Going out?",
                params = mapOf("message" to "I'll check the door and turn things off."),
            ),
            ActionNode(
                id       = "door_check",
                type     = NodeType.TOOL_CALL,
                label    = "Check front door",
                toolName = "smart_home",
                params   = mapOf(
                    "entity_name" to "front door",
                    "action"      to "status",
                ),
                optional     = true,
                overlayTitle = "Checking front door…",
            ),
            ActionNode(
                id       = "heating",
                type     = NodeType.TOOL_CALL,
                label    = "Turn heating off",
                toolName = "smart_home",
                params   = mapOf("entity_name" to "heating", "action" to "off"),
                optional     = true,
                overlayTitle = "Turning heating off…",
            ),
            ActionNode(
                id       = "dnd",
                type     = NodeType.TOOL_CALL,
                label    = "Enable Do Not Disturb",
                toolName = "dnd",
                params   = mapOf("on" to "true"),
                optional     = true,
                overlayTitle = "Silencing notifications…",
            ),
        ),
        edges = listOf(
            ActionEdge("confirm",    "door_check", EdgeCondition.ON_CONFIRM_YES),
            ActionEdge("door_check", "heating",    EdgeCondition.ALWAYS),
            ActionEdge("heating",    "dnd",        EdgeCondition.ALWAYS),
        ),
        startNodeId      = "confirm",
        confirmBeforeStart = false,
    )

    // ─────────────────────────────────────────────────────────────────────────
    // 4. morning_start
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * "Good morning" routine:
     *  1. Turn bedroom lights on to 40%.
     *  2. Disable DND.
     *  3. Give a daily briefing.
     */
    val morningStart: ActionGraph = ActionGraph(
        id           = "morning_start",
        displayName  = "Morning start",
        description  = "Turn lights on, disable Do Not Disturb, and give you a briefing.",
        triggerPhrases = listOf(
            "good morning",
            "morning routine",
            "start my day",
            "wake up routine",
        ),
        nodes = nodes(
            ActionNode(
                id       = "lights_on",
                type     = NodeType.TOOL_CALL,
                label    = "Turn bedroom lights on",
                toolName = "smart_home",
                params   = mapOf(
                    "entity_name" to "bedroom lights",
                    "action"      to "on",
                    "value"       to "40",
                ),
                optional     = true,
                overlayTitle = "Turning lights on…",
            ),
            ActionNode(
                id       = "dnd_off",
                type     = NodeType.TOOL_CALL,
                label    = "Disable Do Not Disturb",
                toolName = "dnd",
                params   = mapOf("on" to "false"),
                optional     = true,
                overlayTitle = "Turning on notifications…",
            ),
            ActionNode(
                id       = "briefing",
                type     = NodeType.TOOL_CALL,
                label    = "Daily briefing",
                toolName = "daily_briefing",
                params   = emptyMap(),
                optional     = true,
                overlayTitle = "Getting your briefing…",
            ),
        ),
        edges = listOf(
            ActionEdge("lights_on", "dnd_off",  EdgeCondition.ALWAYS),
            ActionEdge("dnd_off",   "briefing", EdgeCondition.ALWAYS),
        ),
        startNodeId = "lights_on",
    )

    // ── Registry ──────────────────────────────────────────────────────────────

    /** All built-in templates in matching priority order.  Specific first. */
    val all: List<ActionGraph> = listOf(
        leaveFootball,
        bedtime,
        goingOut,
        morningStart,
    )
}
