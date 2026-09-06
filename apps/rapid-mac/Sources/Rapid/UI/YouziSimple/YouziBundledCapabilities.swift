import Foundation

/// Built-in experts and skills seeded into the product graph so Simple Mode
/// has a useful quick-start strip on a fresh install. Stable identities keep
/// later seeds from duplicating user-edited records.
enum YouziBundledCapabilities: Sendable {
    static let catalogVersion = "1.0.0"
    static let source = YouziManifestSource(
        kind: .builtIn,
        identifier: "youzi-capabilities-v1",
        version: catalogVersion
    )

    private static let origin = Date(timeIntervalSince1970: 0)

    static let helpers: [YouziHelper] = [
        YouziHelper(
            id: uuid("youzi.helper.writing"),
            name: "写作顾问",
            summary: "把想法写成得体、清楚、适合对象的文字。",
            systemInstructions: "先明确读者、目的和语气，再起草，并标出需要确认的句子。",
            methodology: ["先明确对象和语气", "写一版再收紧", "标出需要你确认的句子"],
            source: source,
            isFavorite: true,
            createdAt: origin,
            updatedAt: origin
        ),
        YouziHelper(
            id: uuid("youzi.helper.research"),
            name: "研究助手",
            summary: "把已知、未知和依据分开，给出可核对的结论。",
            systemInstructions: "先分清已知与未知，交叉核对来源，再给出有依据的结论。",
            methodology: ["先分清已知与未知", "交叉核对来源", "给出有依据的结论"],
            source: source,
            createdAt: origin,
            updatedAt: origin
        ),
        YouziHelper(
            id: uuid("youzi.helper.planning"),
            name: "计划教练",
            summary: "把目标拆成今天就能推进的步骤。",
            systemInstructions: "拆成可执行步骤，标出依赖和风险，并排出今天就能做的事。",
            methodology: ["拆成可执行步骤", "标出依赖和风险", "排出今天就能做的"],
            source: source,
            createdAt: origin,
            updatedAt: origin
        ),
        YouziHelper(
            id: uuid("youzi.helper.family"),
            name: "家庭协同",
            summary: "整理共同安排，找出冲突，形成温和的计划。",
            systemInstructions: "整理共同安排，找出冲突，形成温和、可执行的共同计划。",
            methodology: ["整理共同安排", "找出冲突", "形成温和的共同计划"],
            source: source,
            createdAt: origin,
            updatedAt: origin
        ),
    ]

    static let skills: [YouziSkill] = YouziSkillPromptCatalog.entries.map { entry in
        YouziSkill(
            id: uuid("youzi.skill.\(entry.name)"),
            name: entry.name,
            summary: entry.prompts.joined(separator: " / "),
            packageVersion: catalogVersion,
            source: source,
            createdAt: origin,
            updatedAt: origin
        )
    }

    static func uuid(_ identifier: String) -> UUID {
        var bytes = Array(repeating: UInt8(0), count: 16)
        let digest = Array(identifier.utf8)
        for (index, byte) in digest.enumerated() {
            bytes[index % 16] ^= byte
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
