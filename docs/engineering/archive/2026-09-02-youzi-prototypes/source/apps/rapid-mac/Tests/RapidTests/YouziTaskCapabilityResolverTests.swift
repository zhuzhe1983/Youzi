import Foundation
import Testing
@testable import Rapid

@Suite("Youzi task capability resolver")
struct YouziTaskCapabilityResolverTests {
    private let resolver = YouziTaskCapabilityResolver()

    @Test("Helper guidance has explicit precedence and every prompt field is normalized")
    func helperPromptPrecedenceAndNormalization() throws {
        let project = makeProject(
            instructions: "  Keep   the scope.\r\n\r\n   Respect the budget.  ",
            preferences: [" tone ": "  concise   and direct  "]
        )
        let helper = makeHelper(
            instructions: "  Check   constraints first. \r Then compare. ",
            methodology: ["  Gather   facts ", "", "Compare\toptions"],
            outputs: ["  document ", " checklist  "]
        )
        let skill = makeSkill(
            permissions: [.workspaceRead, .networkAccess, .workspaceRead]
        )
        let task = makeTask(
            projectID: project.id,
            helperID: helper.id,
            skillIDs: [skill.id]
        )
        let document = YouziDomainDocument(
            tasks: [task],
            projects: [project],
            helpers: [helper],
            skills: [skill]
        )

        let result = resolver.resolve(
            taskID: task.id,
            in: document,
            input: .init(
                skillInstructionComponents: [
                    skill.id: "  Use   the validated workflow.\r\n\r\n  Cite results. "
                ]
            )
        )

        #expect(result.issues.isEmpty)
        #expect(result.promptComponent.hasPrefix("[YOUZI TASK CAPABILITY CONTEXT]"))
        #expect(result.promptComponent.contains(
            "Helper guidance has precedence for task methodology and output shape."
        ))
        #expect(result.promptComponent.contains(
            "[PROJECT INSTRUCTIONS]\nKeep the scope.\n\nRespect the budget."
        ))
        #expect(result.promptComponent.contains(
            "[PROJECT PREFERENCES]\n- tone: concise and direct"
        ))
        #expect(result.promptComponent.contains(
            "[HELPER GUIDANCE]\nInstructions:\nCheck constraints first.\nThen compare."
        ))
        #expect(result.promptComponent.contains(
            "Methodology:\n1. Gather facts\n2. Compare options"
        ))
        #expect(result.promptComponent.contains(
            "Output guidance:\n- document\n- checklist"
        ))
        #expect(result.promptComponent.contains(
            "[SKILL INSTRUCTIONS]\nUse the validated workflow.\n\nCite results."
        ))
        #expect(!result.promptComponent.contains("\r"))
        #expect(!result.promptComponent.contains("   "))
        #expect(result.requestedPermissionKinds == [.networkAccess, .workspaceRead])
        let projectRange = try #require(
            result.promptComponent.range(of: "[PROJECT INSTRUCTIONS]")
        )
        let helperRange = try #require(
            result.promptComponent.range(of: "[HELPER GUIDANCE]")
        )
        let skillRange = try #require(
            result.promptComponent.range(of: "[SKILL INSTRUCTIONS]")
        )
        #expect(projectRange.lowerBound < helperRange.lowerBound)
        #expect(helperRange.lowerBound < skillRange.lowerBound)
    }

    @Test("Persisted empty-selection intent controls project inheritance")
    func explicitEmptyVersusInheritedSelection() {
        let connector = makeConnector(toolNames: ["calendar.read"])
        let account = makeAccount(connectorID: connector.id)
        let helper = makeHelper(allowedConnectorIDs: [connector.id])
        let skill = makeSkill(connectorDependencyIDs: [connector.id])
        let project = makeProject(
            defaultHelperIDs: [helper.id],
            defaultSkillIDs: [skill.id],
            defaultAccountIDs: [account.id]
        )
        let task = makeTask(projectID: project.id)
        let document = YouziDomainDocument(
            tasks: [task],
            projects: [project],
            helpers: [helper],
            skills: [skill],
            connectors: [connector],
            connectionAccounts: [account]
        )
        let runtime = YouziTaskCapabilityResolverInput(
            builtInToolNames: ["weather"],
            liveConnectorToolNames: [connector.id: ["calendar.read"]],
            skillInstructionComponents: [skill.id: "Read the selected calendar."]
        )

        let inherited = resolver.resolve(taskID: task.id, in: document, input: runtime)
        #expect(inherited.helperIDs == [helper.id])
        #expect(inherited.skillIDs == [skill.id])
        #expect(inherited.connectionAccountIDs == [account.id])
        #expect(inherited.helperSelectionSource == .projectDefault)
        #expect(inherited.skillSelectionSource == .projectDefault)
        #expect(inherited.connectionAccountSelectionSource == .projectDefault)
        #expect(inherited.candidateToolNames == ["calendar.read", "weather"])

        let explicitTask = makeTask(
            projectID: project.id,
            helperSelectionIntent: .explicit,
            skillSelectionIntent: .explicit,
            accountSelectionIntent: .explicit
        )
        var explicitDocument = document
        explicitDocument.tasks = [explicitTask]
        let explicit = resolver.resolve(
            taskID: explicitTask.id,
            in: explicitDocument,
            input: runtime
        )
        #expect(explicit.helperIDs.isEmpty)
        #expect(explicit.skillIDs.isEmpty)
        #expect(explicit.connectionAccountIDs.isEmpty)
        #expect(explicit.helperSelectionSource == .taskExplicit)
        #expect(explicit.skillSelectionSource == .taskExplicit)
        #expect(explicit.connectionAccountSelectionSource == .taskExplicit)
        #expect(explicit.candidateToolNames == ["weather"])
        #expect(explicit.requestedPermissionKinds.isEmpty)
    }

    @Test("Non-empty task selections override project defaults regardless of empty policy")
    func taskSelectionOverridesProjectDefaults() {
        let defaultHelper = makeHelper(id: id(30))
        let explicitHelper = makeHelper(id: id(31))
        let defaultSkill = makeSkill(id: id(32))
        let explicitSkill = makeSkill(id: id(33))
        let defaultConnector = makeConnector(id: id(34), toolNames: ["default.tool"])
        let explicitConnector = makeConnector(id: id(35), toolNames: ["explicit.tool"])
        let defaultAccount = makeAccount(id: id(36), connectorID: defaultConnector.id)
        let explicitAccount = makeAccount(id: id(37), connectorID: explicitConnector.id)
        let project = makeProject(
            defaultHelperIDs: [defaultHelper.id],
            defaultSkillIDs: [defaultSkill.id],
            defaultAccountIDs: [defaultAccount.id]
        )
        let task = makeTask(
            projectID: project.id,
            helperID: explicitHelper.id,
            skillIDs: [explicitSkill.id],
            accountIDs: [explicitAccount.id]
        )
        let document = YouziDomainDocument(
            tasks: [task], projects: [project],
            helpers: [defaultHelper, explicitHelper],
            skills: [defaultSkill, explicitSkill],
            connectors: [defaultConnector, explicitConnector],
            connectionAccounts: [defaultAccount, explicitAccount]
        )

        let result = resolver.resolve(
            taskID: task.id,
            in: document,
            input: .init(
                liveConnectorToolNames: [explicitConnector.id: ["explicit.tool"]],
                skillInstructionComponents: [explicitSkill.id: "Explicit skill."],
                selectionPolicy: .legacyPersistedRecord
            )
        )

        #expect(result.helperIDs == [explicitHelper.id])
        #expect(result.skillIDs == [explicitSkill.id])
        #expect(result.connectionAccountIDs == [explicitAccount.id])
        #expect(result.helperSelectionSource == .taskExplicit)
        #expect(result.skillSelectionSource == .taskExplicit)
        #expect(result.connectionAccountSelectionSource == .taskExplicit)
        // The explicit helper has an empty connector allowlist, so it safely
        // narrows connector candidates to none.
        #expect(result.candidateToolNames.isEmpty)
    }

    @Test("Helper allowlists only narrow selected connector accounts")
    func helperNarrowing() {
        let first = makeConnector(id: id(40), toolNames: ["first.read"])
        let second = makeConnector(id: id(41), toolNames: ["second.read"])
        let unselected = makeConnector(id: id(42), toolNames: ["third.read"])
        let firstAccount = makeAccount(id: id(43), connectorID: first.id)
        let secondAccount = makeAccount(id: id(44), connectorID: second.id)
        let helper = makeHelper(
            id: id(45),
            allowedConnectorIDs: [unselected.id, first.id]
        )
        let task = makeTask(
            helperID: helper.id,
            accountIDs: [secondAccount.id, firstAccount.id]
        )
        let document = YouziDomainDocument(
            tasks: [task], helpers: [helper],
            connectors: [first, second, unselected],
            connectionAccounts: [firstAccount, secondAccount]
        )

        let result = resolver.resolve(
            taskID: task.id,
            in: document,
            input: .init(
                builtInToolNames: ["weather"],
                liveConnectorToolNames: [
                    first.id: ["first.read"],
                    second.id: ["second.read"],
                    unselected.id: ["third.read"],
                ],
                selectionPolicy: .explicitEmpty
            )
        )

        #expect(result.candidateToolNames == ["first.read", "weather"])
        #expect(!result.candidateToolNames.contains("third.read"))
        #expect(result.issues.contains(
            .connectorNotPermittedByHelper(connectorID: second.id, helperID: helper.id)
        ))
    }

    @Test("Skill dependencies intersect connector tools and contribute requests, never grants")
    func skillDependenciesAndRequestedPermissions() {
        let unrelated = makeConnector(id: id(50), toolNames: ["notes.read"])
        let required = makeConnector(id: id(51), toolNames: ["calendar.read"])
        let unrelatedAccount = makeAccount(id: id(52), connectorID: unrelated.id)
        let requiredAccount = makeAccount(id: id(53), connectorID: required.id)
        let skill = makeSkill(
            id: id(54),
            permissions: [.connectorWrite, .networkAccess, .connectorWrite],
            connectorDependencyIDs: [required.id]
        )
        let task = makeTask(
            skillIDs: [skill.id],
            accountIDs: [unrelatedAccount.id, requiredAccount.id]
        )
        let document = YouziDomainDocument(
            tasks: [task], skills: [skill], connectors: [unrelated, required],
            connectionAccounts: [unrelatedAccount, requiredAccount]
        )

        let result = resolver.resolve(
            taskID: task.id,
            in: document,
            input: .init(
                liveConnectorToolNames: [
                    unrelated.id: ["notes.read"],
                    required.id: ["calendar.read"],
                ],
                skillInstructionComponents: [skill.id: "Use calendar evidence."],
                selectionPolicy: .explicitEmpty
            )
        )

        #expect(result.candidateToolNames == ["calendar.read"])
        #expect(result.requestedPermissionKinds == [.connectorWrite, .networkAccess])
        #expect(result.issues.contains(
            .connectorOutsideSelectedSkillDependencies(connectorID: unrelated.id)
        ))
        #expect(!result.issues.contains(where: {
            if case .skillConnectorDependencyUnavailable = $0 { return true }
            return false
        }))
    }

    @Test("A skill dependency without a matching selected connected account is recoverable")
    func missingSkillDependencyAccount() {
        let selected = makeConnector(id: id(60), toolNames: ["notes.read"])
        let required = makeConnector(id: id(61), toolNames: ["calendar.read"])
        let account = makeAccount(id: id(62), connectorID: selected.id)
        let skill = makeSkill(id: id(63), connectorDependencyIDs: [required.id])
        let task = makeTask(skillIDs: [skill.id], accountIDs: [account.id])
        let document = YouziDomainDocument(
            tasks: [task], skills: [skill], connectors: [selected, required],
            connectionAccounts: [account]
        )

        let result = resolver.resolve(
            taskID: task.id,
            in: document,
            input: .init(
                liveConnectorToolNames: [selected.id: ["notes.read"]],
                skillInstructionComponents: [skill.id: "Use calendar."],
                selectionPolicy: .explicitEmpty
            )
        )
        let issue = YouziTaskCapabilityIssue.skillConnectorDependencyUnavailable(
            skillID: skill.id,
            connectorID: required.id
        )

        #expect(result.candidateToolNames.isEmpty)
        #expect(result.issues.contains(issue))
        #expect(issue.recovery == .selectConnectedAccount(connectorID: required.id))
    }

    @Test("A declared missing skill dependency fails closed instead of widening connectors")
    func missingSkillDependencyRecordFailsClosed() {
        let selected = makeConnector(id: id(64), toolNames: ["notes.read"])
        let account = makeAccount(id: id(65), connectorID: selected.id)
        let missingConnectorID = id(66)
        let skill = makeSkill(
            id: id(67), connectorDependencyIDs: [missingConnectorID]
        )
        let task = makeTask(skillIDs: [skill.id], accountIDs: [account.id])
        let document = YouziDomainDocument(
            tasks: [task], skills: [skill], connectors: [selected],
            connectionAccounts: [account]
        )

        let result = resolver.resolve(
            taskID: task.id,
            in: document,
            input: .init(
                liveConnectorToolNames: [selected.id: ["notes.read"]],
                skillInstructionComponents: [skill.id: "Use the required source."],
                selectionPolicy: .explicitEmpty
            )
        )

        #expect(result.candidateToolNames.isEmpty)
        #expect(result.issues.contains(
            .missingRecord(kind: .connector, id: missingConnectorID)
        ))
        #expect(result.issues.contains(
            .skillConnectorDependencyUnavailable(
                skillID: skill.id,
                connectorID: missingConnectorID
            )
        ))
    }

    @Test("Only connected accounts whose connectors are active contribute")
    func connectedAndInactiveAccountStates() {
        let activeConnector = makeConnector(id: id(70), toolNames: ["active.read"])
        let archivedConnector = makeConnector(
            id: id(71), toolNames: ["archived.read"], state: .archived
        )
        let connected = makeAccount(id: id(72), connectorID: activeConnector.id)
        let disconnected = makeAccount(
            id: id(73), connectorID: activeConnector.id, state: .notConnected
        )
        let archived = makeAccount(id: id(74), connectorID: archivedConnector.id)
        let task = makeTask(accountIDs: [connected.id, disconnected.id, archived.id])
        let document = YouziDomainDocument(
            tasks: [task], connectors: [activeConnector, archivedConnector],
            connectionAccounts: [connected, disconnected, archived]
        )

        let result = resolver.resolve(
            taskID: task.id,
            in: document,
            input: .init(
                liveConnectorToolNames: [activeConnector.id: ["active.read"]],
                selectionPolicy: .explicitEmpty
            )
        )

        #expect(result.connectionAccountIDs == [connected.id])
        #expect(result.connectorIDs == [activeConnector.id])
        #expect(result.candidateToolNames == ["active.read"])
        #expect(result.issues.contains(
            .connectionAccountNotConnected(id: disconnected.id, state: .notConnected)
        ))
        #expect(result.issues.contains(
            .inactiveRecord(kind: .connector, id: archivedConnector.id, state: .archived)
        ))
    }

    @Test("Missing and inactive selected records are issues and contribute no authority")
    func missingAndInactiveRecords() {
        let missingHelperID = id(80)
        let disabledSkill = makeSkill(id: id(81), state: .disabled)
        let missingAccountID = id(82)
        let task = makeTask(
            helperID: missingHelperID,
            skillIDs: [disabledSkill.id],
            accountIDs: [missingAccountID]
        )
        let document = YouziDomainDocument(tasks: [task], skills: [disabledSkill])

        let result = resolver.resolve(
            taskID: task.id,
            in: document,
            input: .init(builtInToolNames: ["weather"], selectionPolicy: .explicitEmpty)
        )

        #expect(result.helperIDs.isEmpty)
        #expect(result.skillIDs.isEmpty)
        #expect(result.connectionAccountIDs.isEmpty)
        #expect(result.requestedPermissionKinds.isEmpty)
        #expect(result.candidateToolNames == ["weather"])
        #expect(result.issues.contains(.missingRecord(kind: .helper, id: missingHelperID)))
        #expect(result.issues.contains(
            .inactiveRecord(kind: .skill, id: disabledSkill.id, state: .disabled)
        ))
        #expect(result.issues.contains(
            .missingRecord(kind: .connectionAccount, id: missingAccountID)
        ))
    }

    @Test("Missing live tools and duplicate declarations are exact deterministic issues")
    func missingLiveToolAndDuplicateDeclaration() {
        let connector = makeConnector(
            id: id(90), toolNames: [" beta.read ", "alpha.read", "alpha.read"]
        )
        let account = makeAccount(id: id(91), connectorID: connector.id)
        let task = makeTask(accountIDs: [account.id])
        let document = YouziDomainDocument(
            tasks: [task], connectors: [connector], connectionAccounts: [account]
        )

        let result = resolver.resolve(
            taskID: task.id,
            in: document,
            input: .init(
                liveConnectorToolNames: [connector.id: ["alpha.read"]],
                selectionPolicy: .explicitEmpty
            )
        )

        #expect(result.candidateToolNames == ["alpha.read"])
        #expect(result.issues.contains(
            .connectorToolUnavailable(connectorID: connector.id, toolName: "beta.read")
        ))
        #expect(result.issues.contains(
            .duplicateConnectorToolDeclaration(
                connectorID: connector.id,
                toolName: "alpha.read"
            )
        ))
    }

    @Test("Duplicate stable records and duplicate selections never choose an arbitrary copy")
    func duplicateStableIDs() {
        let connector = makeConnector(id: id(100), toolNames: ["connector.read"])
        let duplicateConnector = makeConnector(
            id: connector.id, toolNames: ["different.read"]
        )
        let account = makeAccount(id: id(101), connectorID: connector.id)
        let duplicateAccount = makeAccount(
            id: account.id, connectorID: connector.id, displayName: "Duplicate"
        )
        let uniqueAccount = makeAccount(id: id(104), connectorID: connector.id)
        let helper = makeHelper(id: id(102), allowedConnectorIDs: [connector.id])
        let duplicateHelper = makeHelper(id: helper.id, instructions: "Different")
        let skill = makeSkill(id: id(103), connectorDependencyIDs: [connector.id])
        let duplicateSkill = makeSkill(id: skill.id, permissions: [.networkAccess])
        let task = makeTask(
            helperID: helper.id,
            skillIDs: [skill.id, skill.id],
            accountIDs: [account.id, account.id, uniqueAccount.id]
        )
        let document = YouziDomainDocument(
            tasks: [task],
            helpers: [helper, duplicateHelper],
            skills: [skill, duplicateSkill],
            connectors: [connector, duplicateConnector],
            connectionAccounts: [account, duplicateAccount, uniqueAccount]
        )

        let result = resolver.resolve(
            taskID: task.id,
            in: document,
            input: .init(builtInToolNames: ["weather"], selectionPolicy: .explicitEmpty)
        )

        #expect(result.helperIDs.isEmpty)
        #expect(result.skillIDs.isEmpty)
        #expect(result.connectionAccountIDs.isEmpty)
        #expect(result.connectorIDs.isEmpty)
        #expect(result.candidateToolNames == ["weather"])
        #expect(result.issues.contains(.duplicateRecord(kind: .helper, id: helper.id)))
        #expect(result.issues.contains(.duplicateRecord(kind: .skill, id: skill.id)))
        #expect(result.issues.contains(
            .duplicateRecord(kind: .connectionAccount, id: account.id)
        ))
        #expect(result.issues.contains(
            .duplicateRecord(kind: .connector, id: connector.id)
        ))
        #expect(result.issues.contains(
            .duplicateSelection(category: .skills, id: skill.id)
        ))
        #expect(result.issues.contains(
            .duplicateSelection(category: .connectionAccounts, id: account.id)
        ))
    }

    @Test("Built-ins remain candidates when connector filtering removes everything")
    func builtInsSurviveConnectorFiltering() {
        let connector = makeConnector(id: id(110), toolNames: ["calendar.read"])
        let account = makeAccount(id: id(111), connectorID: connector.id)
        let helper = makeHelper(id: id(112), allowedConnectorIDs: [])
        let task = makeTask(helperID: helper.id, accountIDs: [account.id])
        let document = YouziDomainDocument(
            tasks: [task], helpers: [helper], connectors: [connector],
            connectionAccounts: [account]
        )

        let result = resolver.resolve(
            taskID: task.id,
            in: document,
            input: .init(
                builtInToolNames: [" weather ", "browse", "weather"],
                liveConnectorToolNames: [connector.id: ["calendar.read"]],
                selectionPolicy: .explicitEmpty
            )
        )

        #expect(result.candidateToolNames == ["browse", "weather"])
        #expect(result.issues.contains(
            .connectorNotPermittedByHelper(connectorID: connector.id, helperID: helper.id)
        ))
    }

    @Test("Shuffling document arrays and runtime input order produces byte-stable context")
    func deterministicUnderShuffledOrder() {
        let connectorA = makeConnector(id: id(120), toolNames: ["a.two", "a.one"])
        let connectorB = makeConnector(id: id(121), toolNames: ["b.one"])
        let accountA = makeAccount(id: id(122), connectorID: connectorA.id)
        let accountB = makeAccount(id: id(123), connectorID: connectorB.id)
        let helperA = makeHelper(
            id: id(124), instructions: "Helper A", allowedConnectorIDs: [connectorA.id, connectorB.id]
        )
        let helperB = makeHelper(
            id: id(125), instructions: "Helper B", allowedConnectorIDs: [connectorB.id, connectorA.id]
        )
        let skillA = makeSkill(id: id(126), connectorDependencyIDs: [connectorA.id, connectorB.id])
        let skillB = makeSkill(id: id(127), connectorDependencyIDs: [connectorB.id, connectorA.id])
        let projectA = makeProject(
            id: id(128),
            defaultHelperIDs: [helperB.id, helperA.id]
        )
        let projectB = makeProject(
            id: projectA.id,
            defaultHelperIDs: [helperA.id, helperB.id]
        )
        let taskA = makeTask(
            id: id(129), projectID: projectA.id,
            skillIDs: [skillB.id, skillA.id],
            accountIDs: [accountB.id, accountA.id]
        )
        let taskB = makeTask(
            id: taskA.id, projectID: projectB.id,
            skillIDs: [skillA.id, skillB.id],
            accountIDs: [accountA.id, accountB.id]
        )
        let firstDocument = YouziDomainDocument(
            tasks: [taskA], projects: [projectA],
            helpers: [helperB, helperA], skills: [skillB, skillA],
            connectors: [connectorB, connectorA],
            connectionAccounts: [accountB, accountA]
        )
        let secondDocument = YouziDomainDocument(
            tasks: [taskB], projects: [projectB],
            helpers: [helperA, helperB], skills: [skillA, skillB],
            connectors: [connectorA, connectorB],
            connectionAccounts: [accountA, accountB]
        )
        let firstInput = YouziTaskCapabilityResolverInput(
            builtInToolNames: ["weather", "browse"],
            liveConnectorToolNames: [
                connectorB.id: ["b.one"],
                connectorA.id: ["a.two", "a.one"],
            ],
            skillInstructionComponents: [skillB.id: "Skill B", skillA.id: "Skill A"]
        )
        let secondInput = YouziTaskCapabilityResolverInput(
            builtInToolNames: ["browse", "weather"],
            liveConnectorToolNames: [
                connectorA.id: ["a.one", "a.two"],
                connectorB.id: ["b.one"],
            ],
            skillInstructionComponents: [skillA.id: "Skill A", skillB.id: "Skill B"]
        )

        #expect(
            resolver.resolve(taskID: taskA.id, in: firstDocument, input: firstInput)
                == resolver.resolve(taskID: taskB.id, in: secondDocument, input: secondInput)
        )
    }

    @Test("Recommendations, unselected connectors, live extras, and prior grants cannot widen authority")
    func noAuthorityWidening() {
        let selectedConnector = makeConnector(id: id(130), toolNames: ["selected.read"])
        let unselectedConnector = makeConnector(id: id(131), toolNames: ["unselected.read"])
        let selectedAccount = makeAccount(id: id(132), connectorID: selectedConnector.id)
        let recommendedSkill = makeSkill(
            id: id(133), permissions: [.networkAccess], connectorDependencyIDs: [unselectedConnector.id]
        )
        let helper = makeHelper(
            id: id(134),
            recommendedSkillIDs: [recommendedSkill.id],
            allowedConnectorIDs: [selectedConnector.id, unselectedConnector.id]
        )
        let task = makeTask(helperID: helper.id, accountIDs: [selectedAccount.id])
        let priorPermission = YouziPermissionRecord(
            taskID: task.id,
            kind: .connectorRead,
            targetIdentifier: unselectedConnector.id.uuidString,
            purpose: "Prior grant",
            duration: .persistent,
            decision: .allowed
        )
        let document = YouziDomainDocument(
            permissions: [priorPermission], tasks: [task], helpers: [helper],
            skills: [recommendedSkill], connectors: [selectedConnector, unselectedConnector],
            connectionAccounts: [selectedAccount]
        )

        let result = resolver.resolve(
            taskID: task.id,
            in: document,
            input: .init(
                builtInToolNames: ["weather"],
                liveConnectorToolNames: [
                    selectedConnector.id: ["selected.read", "undeclared.live"],
                    unselectedConnector.id: ["unselected.read"],
                ],
                skillInstructionComponents: [recommendedSkill.id: "Should not load."],
                selectionPolicy: .explicitEmpty
            )
        )

        #expect(result.skillIDs.isEmpty)
        #expect(result.requestedPermissionKinds.isEmpty)
        #expect(result.candidateToolNames == ["selected.read", "weather"])
        #expect(!result.promptComponent.contains("Should not load."))
        #expect(!result.candidateToolNames.contains("undeclared.live"))
        #expect(!result.candidateToolNames.contains("unselected.read"))
    }

    @Test("Missing skill package instructions are recoverable but do not erase declarations")
    func missingSkillInstructions() {
        let skill = makeSkill(id: id(140), permissions: [.workspaceRead])
        let task = makeTask(skillIDs: [skill.id])
        let document = YouziDomainDocument(tasks: [task], skills: [skill])

        let result = resolver.resolve(
            taskID: task.id,
            in: document,
            input: .init(selectionPolicy: .explicitEmpty)
        )
        let issue = YouziTaskCapabilityIssue.skillInstructionsUnavailable(skillID: skill.id)

        #expect(result.skillIDs == [skill.id])
        #expect(result.requestedPermissionKinds == [.workspaceRead])
        #expect(result.promptComponent.isEmpty)
        #expect(result.issues.contains(issue))
        #expect(issue.recovery == .repairSkillPackage(id: skill.id))
    }

    @Test("Archived projects do not contribute defaults or prompt guidance")
    func inactiveProjectDoesNotContribute() {
        let helper = makeHelper(id: id(150), instructions: "Do not inject")
        let project = makeProject(
            id: id(151), instructions: "Do not inject project", defaultHelperIDs: [helper.id],
            state: .archived
        )
        let task = makeTask(projectID: project.id)
        let document = YouziDomainDocument(
            tasks: [task], projects: [project], helpers: [helper]
        )

        let result = resolver.resolve(
            taskID: task.id,
            in: document,
            input: .init(builtInToolNames: ["weather"])
        )

        #expect(result.projectID == nil)
        #expect(result.helperIDs.isEmpty)
        #expect(result.helperSelectionSource == .none)
        #expect(result.promptComponent.isEmpty)
        #expect(result.candidateToolNames == ["weather"])
        #expect(result.issues.contains(
            .inactiveRecord(kind: .project, id: project.id, state: .archived)
        ))
    }

    @Test("Tool matching is exact and case-sensitive")
    func exactToolNames() {
        let connector = makeConnector(id: id(160), toolNames: ["Calendar.Read"])
        let account = makeAccount(id: id(161), connectorID: connector.id)
        let task = makeTask(accountIDs: [account.id])
        let document = YouziDomainDocument(
            tasks: [task], connectors: [connector], connectionAccounts: [account]
        )

        let result = resolver.resolve(
            taskID: task.id,
            in: document,
            input: .init(
                liveConnectorToolNames: [connector.id: ["calendar.read"]],
                selectionPolicy: .explicitEmpty
            )
        )

        #expect(result.candidateToolNames.isEmpty)
        #expect(result.issues.contains(
            .connectorToolUnavailable(connectorID: connector.id, toolName: "Calendar.Read")
        ))
    }

    @Test("Resolver never projects source, entrypoint, resource, credential, or workspace paths")
    func noMachinePathsInResolvedContext() {
        let forbidden = "/Users/private/Secret"
        let connector = makeConnector(id: id(170), toolNames: [])
        let account = makeAccount(
            id: id(171), connectorID: connector.id, credentialReference: forbidden
        )
        let helper = makeHelper(
            id: id(172),
            allowedConnectorIDs: [connector.id],
            sourceIdentifier: forbidden
        )
        let skill = makeSkill(
            id: id(173), entrypoint: forbidden, resourcePaths: [forbidden]
        )
        let task = makeTask(
            helperID: helper.id, skillIDs: [skill.id], accountIDs: [account.id]
        )
        let document = YouziDomainDocument(
            tasks: [task], helpers: [helper], skills: [skill], connectors: [connector],
            connectionAccounts: [account]
        )

        let result = resolver.resolve(
            taskID: task.id,
            in: document,
            input: .init(
                skillInstructionComponents: [skill.id: "Safe package instructions."],
                selectionPolicy: .explicitEmpty
            )
        )
        let reflected = String(reflecting: result)

        #expect(!result.promptComponent.contains(forbidden))
        #expect(!reflected.contains(forbidden))
    }

    @Test("Missing or duplicate tasks fail closed even when built-ins are supplied")
    func invalidTaskFailsClosed() {
        let taskID = id(180)
        let missing = resolver.resolve(
            taskID: taskID,
            in: .empty,
            input: .init(builtInToolNames: ["weather"])
        )
        #expect(missing.candidateToolNames.isEmpty)
        #expect(missing.issues == [.missingRecord(kind: .task, id: taskID)])

        let first = makeTask(id: taskID, title: "First")
        let second = makeTask(id: taskID, title: "Second")
        let duplicate = resolver.resolve(
            taskID: taskID,
            in: YouziDomainDocument(tasks: [second, first]),
            input: .init(builtInToolNames: ["weather"])
        )
        #expect(duplicate.candidateToolNames.isEmpty)
        #expect(duplicate.issues == [.duplicateRecord(kind: .task, id: taskID)])
    }

    // MARK: - Fixtures

    private func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }

    private func source(identifier: String = "youzi.test") -> YouziManifestSource {
        YouziManifestSource(kind: .builtIn, identifier: identifier, version: "1.0.0")
    }

    private func makeTask(
        id taskID: UUID? = nil,
        title: String = "Task",
        projectID: UUID? = nil,
        helperID: UUID? = nil,
        helperSelectionIntent: YouziTaskSelectionIntent = .inheritProjectDefaults,
        skillIDs: [UUID] = [],
        skillSelectionIntent: YouziTaskSelectionIntent = .inheritProjectDefaults,
        accountIDs: [UUID] = [],
        accountSelectionIntent: YouziTaskSelectionIntent = .inheritProjectDefaults
    ) -> YouziTask {
        YouziTask(
            id: taskID ?? id(1),
            title: title,
            request: "Do the task",
            projectID: projectID,
            helperID: helperID,
            helperSelectionIntent: helperSelectionIntent,
            skillIDs: skillIDs,
            skillSelectionIntent: skillSelectionIntent,
            connectionAccountIDs: accountIDs,
            connectionAccountSelectionIntent: accountSelectionIntent
        )
    }

    private func makeProject(
        id projectID: UUID? = nil,
        instructions: String = "",
        preferences: [String: String] = [:],
        defaultHelperIDs: [UUID] = [],
        defaultSkillIDs: [UUID] = [],
        defaultAccountIDs: [UUID] = [],
        state: YouziRecordState = .active
    ) -> YouziProject {
        YouziProject(
            id: projectID ?? id(2),
            name: "Project",
            instructions: instructions,
            preferences: preferences,
            defaultHelperIDs: defaultHelperIDs,
            defaultSkillIDs: defaultSkillIDs,
            defaultConnectionAccountIDs: defaultAccountIDs,
            state: state
        )
    }

    private func makeHelper(
        id helperID: UUID? = nil,
        instructions: String = "",
        methodology: [String] = [],
        recommendedSkillIDs: [UUID] = [],
        allowedConnectorIDs: [UUID] = [],
        outputs: [String] = [],
        sourceIdentifier: String = "youzi.test.helper",
        state: YouziRecordState = .active
    ) -> YouziHelper {
        YouziHelper(
            id: helperID ?? id(3),
            name: "Helper",
            summary: "A helper",
            systemInstructions: instructions,
            methodology: methodology,
            recommendedSkillIDs: recommendedSkillIDs,
            allowedConnectorIDs: allowedConnectorIDs,
            preferredOutputTypes: outputs,
            source: source(identifier: sourceIdentifier),
            state: state
        )
    }

    private func makeSkill(
        id skillID: UUID? = nil,
        entrypoint: String = "SKILL.md",
        resourcePaths: [String] = [],
        permissions: [YouziPermissionKind] = [],
        connectorDependencyIDs: [UUID] = [],
        state: YouziRecordState = .active
    ) -> YouziSkill {
        YouziSkill(
            id: skillID ?? id(4),
            name: "Skill",
            summary: "A skill",
            packageVersion: "1.0.0",
            entrypoint: entrypoint,
            resourcePaths: resourcePaths,
            requestedPermissions: permissions,
            connectorDependencyIDs: connectorDependencyIDs,
            source: source(identifier: "youzi.test.skill"),
            state: state
        )
    }

    private func makeConnector(
        id connectorID: UUID? = nil,
        toolNames: [String],
        state: YouziRecordState = .active
    ) -> YouziConnector {
        YouziConnector(
            id: connectorID ?? id(5),
            name: "Connector",
            summary: "A connector",
            adapter: .mcp,
            authentication: .custom,
            toolNames: toolNames,
            source: source(identifier: "youzi.test.connector"),
            state: state
        )
    }

    private func makeAccount(
        id accountID: UUID? = nil,
        connectorID: UUID,
        displayName: String = "Account",
        credentialReference: String? = nil,
        state: YouziConnectionState = .connected
    ) -> YouziConnectionAccount {
        YouziConnectionAccount(
            id: accountID ?? id(6),
            connectorID: connectorID,
            displayName: displayName,
            credentialReference: credentialReference,
            state: state
        )
    }
}
