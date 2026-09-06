import Foundation

/// Shared by the scenario selector and the model-facing local tools. Selection
/// and residency are different: a saved preference is never a ready checkmark.
enum YouziScenarioModels {
    static func merge(chat: [ModelEntry], media: [ModelEntry]) -> [ModelEntry] {
        var entries: [String: ModelEntry] = [:]
        for entry in chat + media { entries[entry.alias] = entry }
        return entries.values.sorted { $0.alias.localizedStandardCompare($1.alias) == .orderedAscending }
    }

    static func isReady(_ entry: ModelEntry, in snapshot: ModelResidencySnapshot) -> Bool {
        let identities = Set([entry.alias, entry.hfRepo].compactMap { $0 })
        if snapshot.models.contains(where: {
            identities.contains(where: $0.matches) && ($0.state == "resident" || $0.state == "busy" || $0.state == "loaded")
        }) { return true }
        return entry.kind == .audio && snapshot.audioLanes.contains {
            $0.model.map(identities.contains) == true
                && ($0.state == "resident" || $0.state == "busy")
        }
    }
}
