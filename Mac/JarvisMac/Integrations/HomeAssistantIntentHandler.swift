import Foundation

/// Handles all Home Assistant execute() intents previously inline in JarvisController.
/// Extracted following the per-domain handler pattern — Sprint Q decomposition.
@MainActor final class HomeAssistantIntentHandler {

    private let haEntityRegistry: HAEntityRegistry
    private let haMotionMapper: HAMotionCameraMapper
    private let proactivity: ProactivityEngine
    private let renderer: ResponseRenderer
    private let state: AppState

    var speak: (String) -> Void = { _ in }
    var openOverlay: (OverlayKind) -> Void = { _ in }
    var closeOverlay: (OverlayKind) -> Void = { _ in }
    var setPendingContext: (PendingConversationContext) -> Void = { _ in }
    var currentTranscript: () -> String = { "" }
    /// Closure returning the current SmartHomeClient (may change after settings update).
    var getSmartHome: () -> SmartHomeClient = { DisabledSmartHomeClient() }
    /// Closure that runs homeStatusSummary() on JarvisController.
    var statusSummary: () async -> String = { "" }
    /// Closure returning the last-known HA entity list for query lookups.
    var entityLookup: () -> [HomeEntity] = { [] }

    init(
        haEntityRegistry: HAEntityRegistry,
        haMotionMapper: HAMotionCameraMapper,
        proactivity: ProactivityEngine,
        renderer: ResponseRenderer,
        state: AppState
    ) {
        self.haEntityRegistry = haEntityRegistry
        self.haMotionMapper = haMotionMapper
        self.proactivity = proactivity
        self.renderer = renderer
        self.state = state
    }

    /// Returns true if the intent was handled, false if it is not an HA intent.
    func handle(_ intent: Intent) async -> Bool {
        let smartHome = getSmartHome()
        switch intent {

        case .homeStatus:
            speak(await statusSummary())
            return true

        case .homeTurnOn(let entity):
            let ambiguous: Set<String> = ["", "lights", "all", "all lights", "the lights", "them"]
            if ambiguous.contains(entity.lowercased().trimmingCharacters(in: .whitespaces)) {
                let question = "Which lights — living room, bedroom, kitchen, or all?"
                speak(question)
                setPendingContext(.choice(
                    originalTranscript: currentTranscript(),
                    originalIntent: intent,
                    question: question,
                    choices: ["living room", "bedroom", "kitchen", "office", "all"],
                    onChoice: { room in
                        let name = room == "all" ? "all lights" : "\(room) lights"
                        return .executeIntent(.homeTurnOn(entity: name))
                    }
                ))
                return true
            }
            do {
                try await smartHome.turnOn(entity)
                speak(renderer.render(ResponseKey.homeTurnOnSuccess, ["entity": entity]))
            } catch {
                speak(renderer.render(ResponseKey.homeTurnOnFailure, ["entity": entity]))
            }
            return true

        case .homeTurnOff(let entity):
            let ambiguous: Set<String> = ["", "lights", "all", "all lights", "the lights", "them"]
            if ambiguous.contains(entity.lowercased().trimmingCharacters(in: .whitespaces)) {
                let question = "Which lights — living room, bedroom, kitchen, or all?"
                speak(question)
                setPendingContext(.choice(
                    originalTranscript: currentTranscript(),
                    originalIntent: intent,
                    question: question,
                    choices: ["living room", "bedroom", "kitchen", "office", "all"],
                    onChoice: { room in
                        let name = room == "all" ? "all lights" : "\(room) lights"
                        return .executeIntent(.homeTurnOff(entity: name))
                    }
                ))
                return true
            }
            do {
                try await smartHome.turnOff(entity)
                speak(renderer.render(ResponseKey.homeTurnOffSuccess, ["entity": entity]))
            } catch {
                speak(renderer.render(ResponseKey.homeTurnOffFailure, ["entity": entity]))
            }
            return true

        case .homeQueryEntity(let entity):
            // Try cache first; fall back to a live fetch so the answer is always fresh.
            if let match = entityLookup().first(where: { $0.entityID == entity }) {
                speak(renderer.render(ResponseKey.homeEntityState,
                                      ["name": match.displayName, "state": match.state]))
            } else if smartHome.isConfigured {
                do {
                    let live = try await smartHome.getEntityState(entity)
                    speak(renderer.render(ResponseKey.homeEntityState,
                                          ["name": live.displayName, "state": live.state]))
                } catch {
                    speak(renderer.render(ResponseKey.homeEntityUnknown, ["entity": entity]))
                }
            } else {
                speak(renderer.render(ResponseKey.homeEntityUnknown, ["entity": entity]))
            }
            return true

        case .homeSetBrightness(let entity, let level):
            guard smartHome.isConfigured else {
                speak(renderer.render(ResponseKey.homeNotConfigured)); return true
            }
            let name = await smartHome.friendlyName(for: entity)
            do {
                try await smartHome.setBrightness(entity: entity, level: level)
                speak(renderer.render(ResponseKey.homeBrightnessSuccess,
                                      ["entity": name, "level": "\(level)"]))
            } catch {
                speak(renderer.render(ResponseKey.homeBrightnessFailure, ["entity": name]))
            }
            return true

        case .homeSetColor(let entity, let color):
            guard smartHome.isConfigured else {
                speak(renderer.render(ResponseKey.homeNotConfigured)); return true
            }
            let name = await smartHome.friendlyName(for: entity)
            do {
                try await smartHome.setColor(entity: entity, color: color)
                speak(renderer.render(ResponseKey.homeColorSuccess, ["entity": name, "color": color]))
            } catch {
                speak(renderer.render(ResponseKey.homeColorFailure, ["entity": name]))
            }
            return true

        case .homeActivateScene(let sceneName):
            guard smartHome.isConfigured else {
                speak(renderer.render(ResponseKey.homeNotConfigured)); return true
            }
            do {
                try await smartHome.activateScene(name: sceneName)
                speak(renderer.render(ResponseKey.homeSceneSuccess, ["scene": sceneName]))
            } catch {
                speak(renderer.render(ResponseKey.homeSceneFailure, ["scene": sceneName]))
            }
            return true

        case .homeRunAutomation(let name):
            guard smartHome.isConfigured else {
                speak(renderer.render(ResponseKey.homeNotConfigured)); return true
            }
            Task {
                do {
                    let entityId: String
                    if let resolved = await smartHome.resolveEntity(matching: name) {
                        entityId = resolved
                    } else {
                        entityId = "automation." + name.lowercased()
                            .replacingOccurrences(of: " ", with: "_")
                    }
                    try await smartHome.callServiceRaw(domain: "automation", service: "trigger",
                                                       body: ["entity_id": entityId])
                    self.speak(self.renderer.render(ResponseKey.homeAutomationTriggered, ["name": name]))
                } catch {
                    self.speak(self.renderer.render(ResponseKey.homeAutomationNotFound, ["name": name]))
                }
            }
            return true

        case .homeOpenCover(let entity):
            guard smartHome.isConfigured else {
                speak(renderer.render(ResponseKey.homeNotConfigured)); return true
            }
            let resolved = await smartHome.resolveEntity(matching: entity) ?? entity
            let coverName = await smartHome.friendlyName(for: resolved)
            do {
                try await smartHome.callServiceRaw(domain: "cover", service: "open_cover",
                                                   body: ["entity_id": resolved])
                speak(renderer.render(ResponseKey.homeCoverOpenSuccess, ["entity": coverName]))
            } catch {
                speak(renderer.render(ResponseKey.homeCoverFailure, ["entity": coverName]))
            }
            return true

        case .homeCloseCover(let entity):
            guard smartHome.isConfigured else {
                speak(renderer.render(ResponseKey.homeNotConfigured)); return true
            }
            let resolved = await smartHome.resolveEntity(matching: entity) ?? entity
            let coverName = await smartHome.friendlyName(for: resolved)
            do {
                try await smartHome.callServiceRaw(domain: "cover", service: "close_cover",
                                                   body: ["entity_id": resolved])
                speak(renderer.render(ResponseKey.homeCoverCloseSuccess, ["entity": coverName]))
            } catch {
                speak(renderer.render(ResponseKey.homeCoverFailure, ["entity": coverName]))
            }
            return true

        case .homeLock(let entity):
            guard smartHome.isConfigured else {
                speak(renderer.render(ResponseKey.homeNotConfigured)); return true
            }
            let resolved = await smartHome.resolveEntity(matching: entity) ?? entity
            let lockName = await smartHome.friendlyName(for: resolved)
            do {
                try await smartHome.callServiceRaw(domain: "lock", service: "lock",
                                                   body: ["entity_id": resolved])
                speak(renderer.render(ResponseKey.homeLockSuccess, ["entity": lockName]))
            } catch {
                speak(renderer.render(ResponseKey.homeLockFailure, ["entity": lockName]))
            }
            return true

        case .homeUnlock(let entity):
            guard smartHome.isConfigured else {
                speak(renderer.render(ResponseKey.homeNotConfigured)); return true
            }
            let resolved = await smartHome.resolveEntity(matching: entity) ?? entity
            let unlockName = await smartHome.friendlyName(for: resolved)
            do {
                try await smartHome.callServiceRaw(domain: "lock", service: "unlock",
                                                   body: ["entity_id": resolved])
                speak(renderer.render(ResponseKey.homeUnlockSuccess, ["entity": unlockName]))
            } catch {
                speak(renderer.render(ResponseKey.homeUnlockFailure, ["entity": unlockName]))
            }
            return true

        case .homeShowCamera(let entity):
            guard smartHome.isConfigured else {
                speak(renderer.render(ResponseKey.homeNotConfigured)); return true
            }
            let resolved = await smartHome.resolveEntity(matching: entity) ?? entity
            if let snapURL = smartHome.getCameraSnapshotURL(entity: resolved) {
                state.currentArticleURL = snapURL
                state.currentArticleTitle = entity.capitalized + " Camera"
                state.currentArticleSource = "Home Assistant"
                openOverlay(.article)
                speak(renderer.render(ResponseKey.homeCameraOpened, ["entity": entity]))
            } else {
                speak(renderer.render(ResponseKey.homeCameraUnavailable, ["entity": entity]))
            }
            return true

        case .homeShowCameraOverlay(let entity):
            guard smartHome.isConfigured else {
                speak(renderer.render(ResponseKey.homeNotConfigured)); return true
            }

            // 1. Fast path: in-memory entity registry (populated at startup).
            var registryMatch = haEntityRegistry.resolveCamera(matching: entity)

            // 2. Check motion→camera mappings (covers entities the user configured
            //    manually in Settings even if the registry sync hasn't run yet).
            if registryMatch == nil {
                let needle     = entity.lowercased()
                let needleNorm = needle.replacingOccurrences(of: " ", with: "_")
                if let mapping = haMotionMapper.mappings.first(where: { m in
                    let camID   = m.cameraEntityID.lowercased()
                    let camName = camID.components(separatedBy: ".").last ?? ""
                    return camID.contains(needleNorm)
                        || camName.contains(needle)
                        || needle.contains(camName)
                }) {
                    let friendly = mapping.cameraEntityID
                        .components(separatedBy: ".").last?
                        .replacingOccurrences(of: "_", with: " ")
                        .capitalized ?? mapping.cameraEntityID
                    registryMatch = HAEntity(
                        entityID:     mapping.cameraEntityID,
                        friendlyName: friendly,
                        domain:       "camera",
                        deviceClass:  nil,
                        area:         nil,
                        type:         .camera,
                        aliases:      [],
                        state:        "idle"
                    )
                }
            }

            // 3. Live entity refresh if registry is empty (startup sync may have failed).
            if registryMatch == nil, haEntityRegistry.cameras.isEmpty {
                do {
                    let entities = try await smartHome.getStatus()
                    haEntityRegistry.sync(from: entities)
                    registryMatch = haEntityRegistry.resolveCamera(matching: entity)
                } catch {
                    Log.app.warning("[ha-camera] Live entity refresh failed: \(error.localizedDescription, privacy: .public)")
                }
            }

            // 4. Last resort: normalise spoken phrase to a camera entity ID guess.
            let entityID: String
            let displayName: String
            if let match = registryMatch {
                entityID    = match.entityID
                displayName = match.displayName
            } else {
                entityID = "camera." + entity.lowercased()
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: " ", with: "_")
                displayName = entity.capitalized
            }

            state.haCameraEntityID     = entityID
            state.haCameraFriendlyName = displayName
            openOverlay(.haCamera)
            speak(renderer.render(ResponseKey.haCameraShowing, ["entity": displayName]))
            return true

        case .homeCloseCamera:
            closeOverlay(.haCamera)
            speak(renderer.render(ResponseKey.haCameraClosed))
            return true

        case .homeShowAllCameras:
            guard smartHome.isConfigured else {
                speak(renderer.render(ResponseKey.homeNotConfigured)); return true
            }
            openOverlay(.haAllCameras)
            speak(renderer.render(ResponseKey.haAllCamerasOpened))
            return true

        case .homeMuteAlerts:
            proactivity.mute(.homeAssistant, for: 3600)
            speak(renderer.render(ResponseKey.haAlertsMuted))
            return true

        case .homeUnmuteAlerts:
            proactivity.unmute(.homeAssistant)
            speak(renderer.render(ResponseKey.haAlertsUnmuted))
            return true

        case .homeIgnoreCameraForHour(let entity):
            let entityID = haEntityRegistry.resolveCamera(matching: entity)?.entityID ?? entity
            haMotionMapper.suppressEntity(entityID, for: 3600)
            speak(renderer.render(ResponseKey.haAlertsMuted))
            return true

        case .homeShowHADiagnostics:
            openOverlay(.haDiagnostics)
            speak(renderer.render(ResponseKey.haDiagnosticsOpened))
            return true

        default:
            return false
        }
    }
}
