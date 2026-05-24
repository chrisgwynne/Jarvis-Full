import SwiftUI

// MARK: - Entity display model

struct HAEntityRow: Identifiable {
    let id: String          // entity_id
    let friendlyName: String
    let state: String
    let domain: String      // "light", "switch", "lock", "climate", "cover"
    let room: String        // derived from entity_id or friendly name

    var isOn: Bool {
        switch domain {
        case "lock":   return state == "unlocked"
        case "cover":  return state == "open"
        default:       return state == "on"
        }
    }

    var stateLabel: String {
        switch domain {
        case "lock":   return state == "locked" ? "Locked" : "Unlocked"
        case "cover":  return state == "open" ? "Open" : "Closed"
        default:       return state == "on" ? "On" : "Off"
        }
    }

    var icon: String {
        switch domain {
        case "light":   return isOn ? "lightbulb.fill" : "lightbulb"
        case "switch":  return isOn ? "power.circle.fill" : "power.circle"
        case "lock":    return isOn ? "lock.open.fill" : "lock.fill"
        case "climate": return "thermometer"
        case "cover":   return isOn ? "blinds.vertical.open" : "blinds.vertical.closed"
        default:        return "dot.circle"
        }
    }

    var iconColor: Color {
        switch domain {
        case "light":   return isOn ? .yellow : .secondary
        case "switch":  return isOn ? .blue : .secondary
        case "lock":    return isOn ? .orange : .green
        case "climate": return .cyan
        case "cover":   return isOn ? .teal : .secondary
        default:        return .secondary
        }
    }
}

// MARK: - View

struct HomeOverlayView: View {
    let haClient: SmartHomeClient

    @State private var entityRows: [HAEntityRow] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    /// Debounced reload after toggle bursts.  Holding a single Task lets us
    /// cancel-and-reschedule on every new toggle so a rapid burst produces
    /// exactly one reload (350 ms after the last toggle), not one per tap.
    @State private var pendingReloadTask: Task<Void, Never>? = nil

    private let displayedDomains: Set<String> = ["light", "switch", "lock", "climate", "cover"]

    var groupedByRoom: [(room: String, entities: [HAEntityRow])] {
        let groups = Dictionary(grouping: entityRows) { $0.room }
        return groups
            .sorted { $0.key < $1.key }
            .map { (room: $0.key, entities: $0.value.sorted { $0.friendlyName < $1.friendlyName }) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "house.fill")
                    .foregroundStyle(.yellow)
                Text("Smart Home")
                    .font(.headline)
                Spacer()
                if isLoading {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Button {
                        Task { await loadEntities() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            Group {
                if !haClient.isConfigured {
                    ContentUnavailableView(
                        "Home Assistant Not Connected",
                        systemImage: "house.fill",
                        description: Text("Add your Home Assistant URL and token in Settings")
                    )
                    .padding()
                } else if let error = errorMessage {
                    ContentUnavailableView(
                        "Couldn't Load Devices",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                    .padding()
                } else if entityRows.isEmpty && !isLoading {
                    ContentUnavailableView(
                        "No Devices Found",
                        systemImage: "house",
                        description: Text("No lights, switches, locks, climate, or covers were found.")
                    )
                    .padding()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            ForEach(groupedByRoom, id: \.room) { group in
                                roomSection(group.room, entities: group.entities)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .padding(.bottom, 8)
                    }
                }
            }
        }
        .background(Color.clear)
        .task { await loadEntities() }
        // Cancel any debounced reload when the overlay closes — without this
        // a Task would keep running for 350 ms after view teardown.
        .onDisappear { pendingReloadTask?.cancel() }
    }

    // MARK: Room section

    private func roomSection(_ room: String, entities: [HAEntityRow]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "mappin.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow.opacity(0.8))
                Text(room.uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.yellow.opacity(0.8))
                    .tracking(1.5)
                Spacer()
                Text("\(entities.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 110, maximum: 150))],
                spacing: 8
            ) {
                ForEach(entities) { entity in
                    entityCard(entity)
                }
            }
        }
    }

    // MARK: Entity card

    private func entityCard(_ entity: HAEntityRow) -> some View {
        Button {
            Task { await toggleEntity(entity) }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: entity.icon)
                    .font(.title3)
                    .foregroundStyle(entity.iconColor)
                    .frame(height: 24)
                Text(entity.friendlyName)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .foregroundStyle(entity.isOn ? .primary : .secondary)
                Text(entity.stateLabel)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(entity.isOn ? entity.iconColor : Color.secondary.opacity(0.5))
                    .tracking(0.5)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .background(
                entity.isOn
                    ? entity.iconColor.opacity(0.12)
                    : Color.white.opacity(0.04)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        entity.isOn ? entity.iconColor.opacity(0.35) : Color.white.opacity(0.08),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        // Don't allow toggling climate (no simple on/off)
        .disabled(entity.domain == "climate")
    }

    // MARK: Data loading

    private func loadEntities() async {
        guard haClient.isConfigured else {
            isLoading = false
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            let entities = try await haClient.getStatus()
            entityRows = entities.compactMap { entity -> HAEntityRow? in
                let domain = entity.entityID.components(separatedBy: ".").first ?? ""
                guard displayedDomains.contains(domain) else { return nil }
                let friendlyName = entity.friendlyName ?? entity.entityID
                let room = deriveRoom(from: entity.entityID, friendlyName: friendlyName)
                return HAEntityRow(
                    id: entity.entityID,
                    friendlyName: friendlyName,
                    state: entity.state,
                    domain: domain,
                    room: room
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: Toggle

    private func toggleEntity(_ entity: HAEntityRow) async {
        guard entity.domain != "climate" else { return }
        let service: String
        switch entity.domain {
        case "lock":
            service = entity.isOn ? "lock" : "unlock"
        default:
            service = entity.isOn ? "turn_off" : "turn_on"
        }
        let svcDomain = entity.domain == "lock" ? "lock" : entity.domain
        try? await haClient.callServiceRaw(
            domain: svcDomain,
            service: service,
            body: ["entity_id": entity.id]
        )
        // Coalesce reloads.  Replaces the previous unconditional 600 ms
        // `Task.sleep` + reload which raced when the user tapped multiple
        // tiles in succession (each toggle launched its own reload, and the
        // later reload could see the earlier server state).
        scheduleDebouncedReload()
    }

    /// Cancels any pending reload and schedules a new one ~350 ms in the
    /// future.  Rapid-fire toggles therefore coalesce into exactly ONE
    /// reload, fired after the user stops tapping.  HA service calls
    /// themselves remain unserialised — the server handles concurrent
    /// requests fine and the UI doesn't need to.
    private func scheduleDebouncedReload() {
        pendingReloadTask?.cancel()
        pendingReloadTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000) // 350 ms
            guard !Task.isCancelled else { return }
            await loadEntities()
        }
    }

    // MARK: Room derivation

    /// Derive a human-readable room name from entity_id and friendly name.
    ///
    /// Strategy:
    /// 1. Match entity_id slug against known room prefixes (longest-first wins).
    /// 2. Fall back to the first capitalised word in the friendly name if it
    ///    looks like a room.
    /// 3. Final fallback: "Home".
    private func deriveRoom(from entityId: String, friendlyName: String) -> String {
        // Strip the domain prefix: "light.living_room_lamp" → "living_room_lamp"
        let slug = entityId.components(separatedBy: ".").dropFirst().joined(separator: "_")

        // Sorted longest-first so "master_bedroom" beats "bedroom"
        let roomPrefixes: [String] = [
            "master_bedroom", "guest_bedroom", "kids_bedroom",
            "living_room", "dining_room", "utility_room",
            "back_door", "front_door",
            "bedroom", "bathroom", "kitchen", "office", "hallway",
            "garage", "garden", "lounge", "study", "basement", "attic",
            "entrance", "corridor", "laundry", "nursery", "playroom",
        ]
        for prefix in roomPrefixes {
            if slug.hasPrefix(prefix) || slug.contains("_\(prefix)_") || slug.contains("_\(prefix)") {
                return prefix.replacingOccurrences(of: "_", with: " ").capitalized
            }
        }

        // Fall back: first word of friendly name if it could be a room
        let words = friendlyName.components(separatedBy: " ")
        if words.count >= 2 {
            let firstWord = words[0]
            let knownRoomWords: Set<String> = [
                "Living", "Bedroom", "Kitchen", "Bathroom", "Office", "Hallway",
                "Garage", "Garden", "Lounge", "Study", "Dining", "Basement",
                "Attic", "Master", "Guest", "Front", "Back", "Entrance",
            ]
            if knownRoomWords.contains(firstWord) {
                // Use first two words if the second is also a room word or "Room"/"Door"
                if words.count >= 2 && (words[1] == "Room" || words[1] == "Door" || words[1] == "Bedroom") {
                    return "\(words[0]) \(words[1])"
                }
                return firstWord
            }
        }

        return "Home"
    }
}

#Preview {
    HomeOverlayView(haClient: DisabledSmartHomeClient())
        .frame(width: 480, height: 520)
}
