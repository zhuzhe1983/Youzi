import Foundation

/// Secondary prompt chips shown after a skill is selected. Matching is by
/// skill name so bundled skills, imported packages, and catalog-only rows
/// share one copy table.
enum YouziSkillPromptCatalog: Sendable {
    struct Entry: Equatable, Sendable {
        let name: String
        let prompts: [String]
    }

    static let entries: [Entry] = [
        Entry(name: "文档整理", prompts: ["提炼结论与依据", "列出行动项", "标出待确认问题"]),
        Entry(name: "周计划", prompts: ["规划我的一周", "平衡工作与生活", "排出今天的优先级"]),
        Entry(name: "用心写作", prompts: ["写一封得体的邮件", "改得更自然", "按对象调整语气"]),
        Entry(name: "可靠研究", prompts: ["先分清已知与未知", "交叉核对来源", "给出有依据的结论"]),
        Entry(name: "决策梳理", prompts: ["列出选择与取舍", "说清风险", "给出可解释的建议"]),
        Entry(name: "数据洞察", prompts: ["找出趋势", "标出异常", "给出可行动结论"]),
        Entry(name: "家庭协同", prompts: ["整理本周安排", "找出冲突", "形成温和的共同计划"]),
        Entry(name: "项目推进", prompts: ["拆成里程碑", "标出风险和下一步", "做一次复盘"]),
    ]

    static func prompts(forSkillNamed name: String) -> [String] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }?.prompts ?? []
    }
}
