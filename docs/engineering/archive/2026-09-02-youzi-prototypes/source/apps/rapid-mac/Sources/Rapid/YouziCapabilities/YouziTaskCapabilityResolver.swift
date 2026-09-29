import Foundation

/// Persisted record kinds understood by the task capability resolver.
///
/// These values are deliberately domain-facing, not UI labels. Recovery UI can
/// translate them without the resolver leaking display names or filesystem
/// locations into an execution plan.
enum YouziTaskCapabilityRecordKind: String, Sendable, Equatable {
    case task
    case project
    case helper
    case skill
    case connector
    case connectionAccount
}

enum YouziTaskCapabilitySelectionCategory: String, Sendable, Equatable {
    case helper
    case skills
    case connectionAccounts
}

/// Where the IDs for one selection category came from.
enum YouziTaskCapabilitySelectionSource: String, Sendable, Equatable {
    /// Includes an explicitly empty selection.
    case taskExplicit
    case projectDefault
    case none
}

/// Optional compatibility override for callers that are resolving an
/// in-memory draft which has not been persisted yet. Durable tasks carry this
/// intent on each capability category and are authoritative by default.
enum YouziTaskCapabilityEmptySelectionBehavior: String, Sendable, Equatable {
    case inheritProjectDefaults
    case explicitEmpty
}

private extension YouziTaskSelectionIntent {
    var emptySelectionBehavior: YouziTaskCapabilityEmptySelectionBehavior {
        switch self {
        case .inheritProjectDefaults:
            return .inheritProjectDefaults
        case .explicit:
            return .explicitEmpty
        }
    }
}

struct YouziTaskCapabilitySelectionPolicy: Sendable, Equatable {
    var helperWhenNil: YouziTaskCapabilityEmptySelectionBehavior
    var skillsWhenEmpty: YouziTaskCapabilityEmptySelectionBehavior
    var connectionAccountsWhenEmpty: YouziTaskCapabilityEmptySelectionBehavior

    /// The migration default for records written before selection intent was
    /// persisted: nil/empty means inherit the active project's defaults.
    static let legacyPersistedRecord = YouziTaskCapabilitySelectionPolicy(
        helperWhenNil: .inheritProjectDefaults,
        skillsWhenEmpty: .inheritProjectDefaults,
        connectionAccountsWhenEmpty: .inheritProjectDefaults
    )

    /// Compatibility shorthand for callers resolving a not-yet-saved draft.
    static let explicitEmpty = YouziTaskCapabilitySelectionPolicy(
        helperWhenNil: .explicitEmpty,
        skillsWhenEmpty: .explicitEmpty,
        connectionAccountsWhenEmpty: .explicitEmpty
    )
}

struct YouziTaskCapabilityResolverInput: Sendable, Equatable {
    /// Built-ins are supplied separately because helper/skill connector filters
    /// never grant or remove built-in authority. They remain candidates for the
    /// later enablement and permission gates.
    var builtInToolNames: [String]
    /// Runtime-discovered connector tools keyed by stable domain connector ID.
    /// A name present under another connector never satisfies this connector.
    var liveConnectorToolNames: [UUID: [String]]
    /// Validated SKILL.md instruction text loaded by the package service. The
    /// resolver never reads package paths or executes package contents.
    var skillInstructionComponents: [UUID: String]
    /// When nil, the resolver reads the three durable selection-intent fields
    /// from the task. This prevents UI state from silently changing authority.
    var selectionPolicy: YouziTaskCapabilitySelectionPolicy?

    init(
        builtInToolNames: [String] = [],
        liveConnectorToolNames: [UUID: [String]] = [:],
        skillInstructionComponents: [UUID: String] = [:],
        selectionPolicy: YouziTaskCapabilitySelectionPolicy? = nil
    ) {
        self.builtInToolNames = builtInToolNames
        self.liveConnectorToolNames = liveConnectorToolNames
        self.skillInstructionComponents = skillInstructionComponents
        self.selectionPolicy = selectionPolicy
    }
}

enum YouziTaskCapabilityRecovery: Sendable, Equatable {
    case chooseExistingRecord(kind: YouziTaskCapabilityRecordKind)
    case repairDuplicateRecord(kind: YouziTaskCapabilityRecordKind, id: UUID)
    case removeDuplicateSelection(category: YouziTaskCapabilitySelectionCategory, id: UUID)
    case enableRecord(kind: YouziTaskCapabilityRecordKind, id: UUID)
    case reconnectAccount(id: UUID)
    case repairSkillPackage(id: UUID)
    case selectConnectedAccount(connectorID: UUID)
    case chooseCompatibleHelper(helperID: UUID, connectorID: UUID)
    case reviewSkillDependencies(connectorID: UUID)
    case enableRuntimeTool(connectorID: UUID, toolName: String)
    case repairConnectorDeclaration(connectorID: UUID, toolName: String)
}

/// A deterministic, non-authorizing problem found while resolving a task.
enum YouziTaskCapabilityIssue: Sendable, Equatable {
    case missingRecord(kind: YouziTaskCapabilityRecordKind, id: UUID)
    case duplicateRecord(kind: YouziTaskCapabilityRecordKind, id: UUID)
    case duplicateSelection(category: YouziTaskCapabilitySelectionCategory, id: UUID)
    case inactiveRecord(
        kind: YouziTaskCapabilityRecordKind,
        id: UUID,
        state: YouziRecordState
    )
    case connectionAccountNotConnected(id: UUID, state: YouziConnectionState)
    case skillInstructionsUnavailable(skillID: UUID)
    case skillConnectorDependencyUnavailable(skillID: UUID, connectorID: UUID)
    case connectorNotPermittedByHelper(connectorID: UUID, helperID: UUID)
    case connectorOutsideSelectedSkillDependencies(connectorID: UUID)
    case connectorToolUnavailable(connectorID: UUID, toolName: String)
    case duplicateConnectorToolDeclaration(connectorID: UUID, toolName: String)

    var recovery: YouziTaskCapabilityRecovery {
        switch self {
        case .missingRecord(let kind, _):
            return .chooseExistingRecord(kind: kind)
        case .duplicateRecord(let kind, let id):
            return .repairDuplicateRecord(kind: kind, id: id)
        case .duplicateSelection(let category, let id):
            return .removeDuplicateSelection(category: category, id: id)
        case .inactiveRecord(let kind, let id, _):
            return .enableRecord(kind: kind, id: id)
        case .connectionAccountNotConnected(let id, _):
            return .reconnectAccount(id: id)
        case .skillInstructionsUnavailable(let skillID):
            return .repairSkillPackage(id: skillID)
        case .skillConnectorDependencyUnavailable(_, let connectorID):
            return .selectConnectedAccount(connectorID: connectorID)
        case .connectorNotPermittedByHelper(let connectorID, let helperID):
            return .chooseCompatibleHelper(helperID: helperID, connectorID: connectorID)
        case .connectorOutsideSelectedSkillDependencies(let connectorID):
            return .reviewSkillDependencies(connectorID: connectorID)
        case .connectorToolUnavailable(let connectorID, let toolName):
            return .enableRuntimeTool(connectorID: connectorID, toolName: toolName)
        case .duplicateConnectorToolDeclaration(let connectorID, let toolName):
            return .repairConnectorDeclaration(connectorID: connectorID, toolName: toolName)
        }
    }

    fileprivate var sortKey: String {
        func id(_ value: UUID) -> String { value.uuidString.lowercased() }
        switch self {
        case .missingRecord(let kind, let recordID):
            return "01|\(kind.rawValue)|\(id(recordID))"
        case .duplicateRecord(let kind, let recordID):
            return "02|\(kind.rawValue)|\(id(recordID))"
        case .duplicateSelection(let category, let recordID):
            return "03|\(category.rawValue)|\(id(recordID))"
        case .inactiveRecord(let kind, let recordID, let state):
            return "04|\(kind.rawValue)|\(id(recordID))|\(state.rawValue)"
        case .connectionAccountNotConnected(let accountID, let state):
            return "05|\(id(accountID))|\(state.rawValue)"
        case .skillInstructionsUnavailable(let skillID):
            return "06|\(id(skillID))"
        case .skillConnectorDependencyUnavailable(let skillID, let connectorID):
            return "07|\(id(skillID))|\(id(connectorID))"
        case .connectorNotPermittedByHelper(let connectorID, let helperID):
            return "08|\(id(connectorID))|\(id(helperID))"
        case .connectorOutsideSelectedSkillDependencies(let connectorID):
            return "09|\(id(connectorID))"
        case .connectorToolUnavailable(let connectorID, let toolName):
            return "10|\(id(connectorID))|\(toolName)"
        case .duplicateConnectorToolDeclaration(let connectorID, let toolName):
            return "11|\(id(connectorID))|\(toolName)"
        }
    }
}

struct YouziResolvedTaskCapabilityContext: Sendable, Equatable {
    let taskID: UUID
    let projectID: UUID?
    let helperIDs: [UUID]
    let skillIDs: [UUID]
    let connectionAccountIDs: [UUID]
    let connectorIDs: [UUID]
    let helperSelectionSource: YouziTaskCapabilitySelectionSource
    let skillSelectionSource: YouziTaskCapabilitySelectionSource
    let connectionAccountSelectionSource: YouziTaskCapabilitySelectionSource
    /// One normalized component for the canonical leading system instruction
    /// row. It is empty when no active selected record contributes guidance.
    let promptComponent: String
    /// Candidates only. The later global-enable, domain-permission, and
    /// low-level approval gates still decide whether a call can execute.
    let candidateToolNames: [String]
    /// Permissions requested by active selected skills. These are not grants.
    let requestedPermissionKinds: [YouziPermissionKind]
    let issues: [YouziTaskCapabilityIssue]
}

/// Pure, deterministic projection from the persisted graph plus an explicit
/// runtime snapshot. It performs no I/O, mutation, permission decision, tool
/// execution, model lookup, or global-state access.
struct YouziTaskCapabilityResolver: Sendable {
    func resolve(
        taskID: UUID,
        in document: YouziDomainDocument,
        input: YouziTaskCapabilityResolverInput = .init()
    ) -> YouziResolvedTaskCapabilityContext {
        let taskIndex = RecordIndex(document.tasks)
        let projectIndex = RecordIndex(document.projects)
        let helperIndex = RecordIndex(document.helpers)
        let skillIndex = RecordIndex(document.skills)
        let connectorIndex = RecordIndex(document.connectors)
        let accountIndex = RecordIndex(document.connectionAccounts)
        var issues: [YouziTaskCapabilityIssue] = []

        guard let task = resolvedRecord(
            taskID,
            kind: .task,
            index: taskIndex,
            issues: &issues
        ) else {
            return YouziResolvedTaskCapabilityContext(
                taskID: taskID,
                projectID: nil,
                helperIDs: [],
                skillIDs: [],
                connectionAccountIDs: [],
                connectorIDs: [],
                helperSelectionSource: .none,
                skillSelectionSource: .none,
                connectionAccountSelectionSource: .none,
                promptComponent: "",
                candidateToolNames: [],
                requestedPermissionKinds: [],
                issues: finalizedIssues(issues)
            )
        }

        let project = task.projectID.flatMap { projectID in
            resolvedActiveRecord(
                projectID,
                kind: .project,
                index: projectIndex,
                state: \YouziProject.state,
                issues: &issues
            )
        }

        let selectionPolicy = input.selectionPolicy ?? .init(
            helperWhenNil: task.helperSelectionIntent.emptySelectionBehavior,
            skillsWhenEmpty: task.skillSelectionIntent.emptySelectionBehavior,
            connectionAccountsWhenEmpty:
                task.connectionAccountSelectionIntent.emptySelectionBehavior
        )

        let helperSelection = selectedIDs(
            taskIDs: task.helperID.map { [$0] } ?? [],
            projectIDs: project?.defaultHelperIDs ?? [],
            emptyBehavior: selectionPolicy.helperWhenNil,
            hasActiveProject: project != nil,
            category: .helper,
            issues: &issues
        )
        let skillSelection = selectedIDs(
            taskIDs: task.skillIDs,
            projectIDs: project?.defaultSkillIDs ?? [],
            emptyBehavior: selectionPolicy.skillsWhenEmpty,
            hasActiveProject: project != nil,
            category: .skills,
            issues: &issues
        )
        let accountSelection = selectedIDs(
            taskIDs: task.connectionAccountIDs,
            projectIDs: project?.defaultConnectionAccountIDs ?? [],
            emptyBehavior: selectionPolicy.connectionAccountsWhenEmpty,
            hasActiveProject: project != nil,
            category: .connectionAccounts,
            issues: &issues
        )

        let helpers: [YouziHelper] = helperSelection.ids.compactMap { helperID in
            resolvedActiveRecord(
                helperID,
                kind: .helper,
                index: helperIndex,
                state: \YouziHelper.state,
                issues: &issues
            )
        }
        let skills: [YouziSkill] = skillSelection.ids.compactMap { skillID in
            resolvedActiveRecord(
                skillID,
                kind: .skill,
                index: skillIndex,
                state: \YouziSkill.state,
                issues: &issues
            )
        }

        var selectedAccounts: [YouziConnectionAccount] = []
        var selectedConnectorsByID: [UUID: YouziConnector] = [:]
        for accountID in accountSelection.ids {
            guard let account = resolvedRecord(
                accountID,
                kind: .connectionAccount,
                index: accountIndex,
                issues: &issues
            ) else { continue }
            guard account.state == .connected else {
                appendIssue(
                    .connectionAccountNotConnected(id: account.id, state: account.state),
                    to: &issues
                )
                continue
            }
            guard let connector = resolvedActiveRecord(
                account.connectorID,
                kind: .connector,
                index: connectorIndex,
                state: \YouziConnector.state,
                issues: &issues
            ) else { continue }
            selectedAccounts.append(account)
            selectedConnectorsByID[connector.id] = connector
        }

        let helperConnectorAllowlist = resolvedHelperConnectorAllowlist(
            helpers: helpers,
            connectorIndex: connectorIndex,
            issues: &issues
        )
        let skillDependencies = resolvedSkillDependencies(
            skills: skills,
            connectorIndex: connectorIndex,
            selectedConnectorIDs: Set(selectedConnectorsByID.keys),
            issues: &issues
        )

        var eligibleConnectorIDs = Set(selectedConnectorsByID.keys)
        if let helperConnectorAllowlist {
            for connectorID in eligibleConnectorIDs {
                for helper in helpers where !helper.allowedConnectorIDs.contains(connectorID) {
                    appendIssue(
                        .connectorNotPermittedByHelper(
                            connectorID: connectorID,
                            helperID: helper.id
                        ),
                        to: &issues
                    )
                }
            }
            eligibleConnectorIDs.formIntersection(helperConnectorAllowlist)
        }
        if skillDependencies.hasDeclarations {
            for connectorID in eligibleConnectorIDs
            where !skillDependencies.connectorIDs.contains(connectorID) {
                appendIssue(
                    .connectorOutsideSelectedSkillDependencies(connectorID: connectorID),
                    to: &issues
                )
            }
            eligibleConnectorIDs.formIntersection(skillDependencies.connectorIDs)
        }

        var candidateTools = Set(normalizedToolNames(input.builtInToolNames))
        for connectorID in sortedIDs(eligibleConnectorIDs) {
            guard let connector = selectedConnectorsByID[connectorID] else { continue }
            let declared = normalizedToolNames(connector.toolNames)
            for toolName in duplicateNormalizedToolNames(connector.toolNames) {
                appendIssue(
                    .duplicateConnectorToolDeclaration(
                        connectorID: connectorID,
                        toolName: toolName
                    ),
                    to: &issues
                )
            }
            let live = Set(normalizedToolNames(input.liveConnectorToolNames[connectorID] ?? []))
            for toolName in declared {
                if live.contains(toolName) {
                    candidateTools.insert(toolName)
                } else {
                    appendIssue(
                        .connectorToolUnavailable(
                            connectorID: connectorID,
                            toolName: toolName
                        ),
                        to: &issues
                    )
                }
            }
        }

        let prompt = promptComponent(
            project: project,
            helpers: helpers,
            skills: skills,
            skillInstructions: input.skillInstructionComponents,
            issues: &issues
        )
        let permissionsByName = Dictionary(
            skills.flatMap(\.requestedPermissions).map { ($0.rawValue, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return YouziResolvedTaskCapabilityContext(
            taskID: task.id,
            projectID: project?.id,
            helperIDs: sortedIDs(helpers.map(\.id)),
            skillIDs: sortedIDs(skills.map(\.id)),
            connectionAccountIDs: sortedIDs(selectedAccounts.map(\.id)),
            connectorIDs: sortedIDs(selectedConnectorsByID.keys),
            helperSelectionSource: helperSelection.source,
            skillSelectionSource: skillSelection.source,
            connectionAccountSelectionSource: accountSelection.source,
            promptComponent: prompt,
            candidateToolNames: candidateTools.sorted(),
            requestedPermissionKinds: permissionsByName.values.sorted {
                $0.rawValue < $1.rawValue
            },
            issues: finalizedIssues(issues)
        )
    }
}

// MARK: - Deterministic record and selection resolution

private struct RecordIndex<Record: Identifiable> where Record.ID == UUID {
    let records: [UUID: Record]
    let duplicateIDs: Set<UUID>

    init(_ values: [Record]) {
        var grouped: [UUID: [Record]] = [:]
        for value in values {
            grouped[value.id, default: []].append(value)
        }
        records = grouped.compactMapValues { $0.count == 1 ? $0[0] : nil }
        duplicateIDs = Set(grouped.compactMap { $0.value.count > 1 ? $0.key : nil })
    }
}

private struct SelectedIDs {
    let ids: [UUID]
    let source: YouziTaskCapabilitySelectionSource
}

private struct ResolvedSkillDependencies {
    let connectorIDs: Set<UUID>
    /// Distinguishes "selected skills declare no connector dependency" from
    /// "they declared dependencies, but every dependency is broken." The
    /// latter must filter to no connector tools rather than widen authority.
    let hasDeclarations: Bool
}

private func resolvedRecord<Record>(
    _ id: UUID,
    kind: YouziTaskCapabilityRecordKind,
    index: RecordIndex<Record>,
    issues: inout [YouziTaskCapabilityIssue]
) -> Record? {
    if index.duplicateIDs.contains(id) {
        appendIssue(.duplicateRecord(kind: kind, id: id), to: &issues)
        return nil
    }
    guard let record = index.records[id] else {
        appendIssue(.missingRecord(kind: kind, id: id), to: &issues)
        return nil
    }
    return record
}

private func resolvedActiveRecord<Record>(
    _ id: UUID,
    kind: YouziTaskCapabilityRecordKind,
    index: RecordIndex<Record>,
    state: KeyPath<Record, YouziRecordState>,
    issues: inout [YouziTaskCapabilityIssue]
) -> Record? {
    guard let record = resolvedRecord(id, kind: kind, index: index, issues: &issues)
    else { return nil }
    let recordState = record[keyPath: state]
    guard recordState == .active else {
        appendIssue(
            .inactiveRecord(kind: kind, id: id, state: recordState),
            to: &issues
        )
        return nil
    }
    return record
}

private func selectedIDs(
    taskIDs: [UUID],
    projectIDs: [UUID],
    emptyBehavior: YouziTaskCapabilityEmptySelectionBehavior,
    hasActiveProject: Bool,
    category: YouziTaskCapabilitySelectionCategory,
    issues: inout [YouziTaskCapabilityIssue]
) -> SelectedIDs {
    let source: YouziTaskCapabilitySelectionSource
    let raw: [UUID]
    if !taskIDs.isEmpty {
        source = .taskExplicit
        raw = taskIDs
    } else if emptyBehavior == .explicitEmpty {
        source = .taskExplicit
        raw = []
    } else if hasActiveProject {
        source = .projectDefault
        raw = projectIDs
    } else {
        source = .none
        raw = []
    }

    var seen = Set<UUID>()
    var unique: [UUID] = []
    for id in sortedIDs(raw) {
        if seen.insert(id).inserted {
            unique.append(id)
        } else {
            appendIssue(.duplicateSelection(category: category, id: id), to: &issues)
        }
    }
    return SelectedIDs(ids: unique, source: source)
}

private func resolvedHelperConnectorAllowlist(
    helpers: [YouziHelper],
    connectorIndex: RecordIndex<YouziConnector>,
    issues: inout [YouziTaskCapabilityIssue]
) -> Set<UUID>? {
    guard !helpers.isEmpty else { return nil }
    var intersection: Set<UUID>?
    for helper in helpers.sorted(by: stableIDOrder) {
        let valid = Set(uniqueIDs(helper.allowedConnectorIDs).compactMap { connectorID in
            resolvedActiveRecord(
                connectorID,
                kind: .connector,
                index: connectorIndex,
                state: \YouziConnector.state,
                issues: &issues
            )?.id
        })
        if let existing = intersection {
            intersection = existing.intersection(valid)
        } else {
            intersection = valid
        }
    }
    return intersection ?? []
}

private func resolvedSkillDependencies(
    skills: [YouziSkill],
    connectorIndex: RecordIndex<YouziConnector>,
    selectedConnectorIDs: Set<UUID>,
    issues: inout [YouziTaskCapabilityIssue]
) -> ResolvedSkillDependencies {
    var dependencies = Set<UUID>()
    var hasDeclarations = false
    for skill in skills.sorted(by: stableIDOrder) {
        if !skill.connectorDependencyIDs.isEmpty { hasDeclarations = true }
        for connectorID in uniqueIDs(skill.connectorDependencyIDs) {
            guard let connector = resolvedActiveRecord(
                connectorID,
                kind: .connector,
                index: connectorIndex,
                state: \YouziConnector.state,
                issues: &issues
            ) else {
                appendIssue(
                    .skillConnectorDependencyUnavailable(
                        skillID: skill.id,
                        connectorID: connectorID
                    ),
                    to: &issues
                )
                continue
            }
            dependencies.insert(connector.id)
            if !selectedConnectorIDs.contains(connector.id) {
                appendIssue(
                    .skillConnectorDependencyUnavailable(
                        skillID: skill.id,
                        connectorID: connector.id
                    ),
                    to: &issues
                )
            }
        }
    }
    return ResolvedSkillDependencies(
        connectorIDs: dependencies,
        hasDeclarations: hasDeclarations
    )
}

// MARK: - Prompt assembly

private func promptComponent(
    project: YouziProject?,
    helpers: [YouziHelper],
    skills: [YouziSkill],
    skillInstructions: [UUID: String],
    issues: inout [YouziTaskCapabilityIssue]
) -> String {
    var sections: [String] = []

    if let project {
        if let instructions = normalizedPromptText(project.instructions) {
            sections.append("[PROJECT INSTRUCTIONS]\n\(instructions)")
        }
        let preferences = project.preferences.keys.sorted().compactMap { key -> String? in
            guard let normalizedKey = normalizedSingleLine(key),
                  let rawValue = project.preferences[key],
                  let normalizedValue = normalizedSingleLine(rawValue)
            else { return nil }
            return "- \(normalizedKey): \(normalizedValue)"
        }
        if !preferences.isEmpty {
            sections.append("[PROJECT PREFERENCES]\n\(preferences.joined(separator: "\n"))")
        }
    }

    let helperBlocks = helpers.sorted(by: stableIDOrder).compactMap { helper -> String? in
        var parts: [String] = []
        if let instructions = normalizedPromptText(helper.systemInstructions) {
            parts.append("Instructions:\n\(instructions)")
        }
        let methodology = helper.methodology.compactMap(normalizedSingleLine)
        if !methodology.isEmpty {
            parts.append(
                "Methodology:\n" + methodology.enumerated().map {
                    "\($0.offset + 1). \($0.element)"
                }.joined(separator: "\n")
            )
        }
        let outputs = helper.preferredOutputTypes.compactMap(normalizedSingleLine)
        if !outputs.isEmpty {
            parts.append("Output guidance:\n" + outputs.map { "- \($0)" }.joined(separator: "\n"))
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n")
    }
    if !helperBlocks.isEmpty {
        sections.append("[HELPER GUIDANCE]\n" + helperBlocks.joined(separator: "\n\n"))
    }

    var skillBlocks: [String] = []
    for skill in skills.sorted(by: stableIDOrder) {
        guard let instructions = skillInstructions[skill.id].flatMap(normalizedPromptText) else {
            appendIssue(.skillInstructionsUnavailable(skillID: skill.id), to: &issues)
            continue
        }
        skillBlocks.append(instructions)
    }
    if !skillBlocks.isEmpty {
        sections.append("[SKILL INSTRUCTIONS]\n" + skillBlocks.joined(separator: "\n\n"))
    }

    guard !sections.isEmpty else { return "" }
    let preamble = """
    [YOUZI TASK CAPABILITY CONTEXT]
    Project guidance provides background. Helper guidance has precedence for task methodology and output shape. Skill instructions refine execution but never grant tools or override application safety, user instructions, or permission gates.
    """
    return ([preamble] + sections).joined(separator: "\n\n")
}

private func normalizedPromptText(_ value: String) -> String? {
    let canonicalNewlines = value
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
    var lines: [String] = []
    var previousWasBlank = true
    for rawLine in canonicalNewlines.split(separator: "\n", omittingEmptySubsequences: false) {
        let normalized = rawLine.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if normalized.isEmpty {
            if !previousWasBlank {
                lines.append("")
            }
            previousWasBlank = true
        } else {
            lines.append(normalized)
            previousWasBlank = false
        }
    }
    while lines.last?.isEmpty == true { lines.removeLast() }
    guard !lines.isEmpty else { return nil }
    return lines.joined(separator: "\n")
}

private func normalizedSingleLine(_ value: String) -> String? {
    let normalized = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return normalized.isEmpty ? nil : normalized
}

// MARK: - Stable collection helpers

private func normalizedToolNames(_ values: [String]) -> [String] {
    Array(Set(values.compactMap(normalizedSingleLine))).sorted()
}

private func duplicateNormalizedToolNames(_ values: [String]) -> [String] {
    var counts: [String: Int] = [:]
    for name in values.compactMap(normalizedSingleLine) {
        counts[name, default: 0] += 1
    }
    return counts.compactMap { $0.value > 1 ? $0.key : nil }.sorted()
}

private func uniqueIDs(_ values: [UUID]) -> [UUID] {
    sortedIDs(Set(values))
}

private func sortedIDs<S: Sequence>(_ values: S) -> [UUID] where S.Element == UUID {
    values.sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
}

private func stableIDOrder<Record: Identifiable>(_ lhs: Record, _ rhs: Record) -> Bool
where Record.ID == UUID {
    lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
}

private func appendIssue(
    _ issue: YouziTaskCapabilityIssue,
    to issues: inout [YouziTaskCapabilityIssue]
) {
    if !issues.contains(issue) { issues.append(issue) }
}

private func finalizedIssues(
    _ issues: [YouziTaskCapabilityIssue]
) -> [YouziTaskCapabilityIssue] {
    issues.sorted { $0.sortKey < $1.sortKey }
}
