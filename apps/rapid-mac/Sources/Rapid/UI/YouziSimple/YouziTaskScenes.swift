import SwiftUI

/// Scenes only suggest draft text. They never run a task or select a model.
enum YouziTaskScene: String, CaseIterable, Identifiable {
    case writing, finance, data, slides, research, planning
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .writing: "doc.text"
        case .finance: "chart.line.uptrend.xyaxis"
        case .data: "tablecells"
        case .slides: "rectangle.on.rectangle"
        case .research: "magnifyingglass"
        case .planning: "list.bullet.clipboard"
        }
    }
    func title(chinese: Bool) -> String {
        switch self {
        case .writing: chinese ? "创作文档" : "Writing"
        case .finance: chinese ? "金融服务" : "Finance"
        case .data: chinese ? "分析数据" : "Data"
        case .slides: chinese ? "制作演示" : "Presentations"
        case .research: chinese ? "深度研究" : "Research"
        case .planning: chinese ? "策划方案" : "Planning"
        }
    }
    func prompts(chinese: Bool) -> [String] {
        switch self {
        case .writing: chinese ? ["把我的想法整理成一份结构清晰的文档", "根据会议记录，整理结论和待办", "帮我润色一封邮件，保留原意"] : ["Turn my notes into a well-structured document", "Extract decisions and action items from meeting notes", "Polish an email while keeping its meaning"]
        case .finance: chinese ? ["整理今天的三条财经要闻，附上来源", "分析我提供的公司年报，列出关键指标和风险", "帮我制作一份收入与支出记录表"] : ["Summarize three financial news stories with sources", "Analyze an annual report's key metrics and risks", "Create an income and expense tracker"]
        case .data: chinese ? ["分析这份表格，找出趋势和异常", "清理重复数据，并说明处理规则", "把关键指标整理成图表和摘要"] : ["Find trends and anomalies in this spreadsheet", "Clean duplicate records and explain the rules", "Create charts and a summary of key metrics"]
        case .slides: chinese ? ["把这份资料整理成汇报演示的大纲", "帮我设计一份项目介绍，突出重点", "为现有演示补充逐页讲稿"] : ["Turn these materials into a presentation outline", "Plan a focused project introduction", "Write speaker notes for each slide"]
        case .research: chinese ? ["围绕这个问题收集资料，并注明来源", "比较几种解决方案的优缺点和适用条件", "梳理一项技术的发展脉络与争议"] : ["Research a question and cite the sources", "Compare solutions, tradeoffs and constraints", "Trace a technology's history and open questions"]
        case .planning: chinese ? ["把目标拆成可执行的步骤和里程碑", "帮我制定活动方案与准备清单", "梳理项目风险，并给出应对措施"] : ["Break a goal into actions and milestones", "Plan an event and its preparation checklist", "Identify project risks and mitigations"]
        }
    }
}

struct YouziTaskSceneTabs: View {
    @Environment(YouziI18nConfig.self) private var i18n
    @Binding var selection: YouziTaskScene
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(YouziTaskScene.allCases) { scene in
                    Button { selection = scene } label: {
                        Label(scene.title(chinese: i18n.isChinese), systemImage: scene.symbol)
                            .font(RapidFont.secondary).fixedSize()
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .foregroundStyle(selection == scene ? RapidTheme.brandPrimary : RapidTheme.textSecondary)
                            .background(selection == scene ? RapidTheme.brandPrimaryTint : RapidTheme.surfaceRaised, in: Capsule())
                            .overlay(Capsule().strokeBorder(selection == scene ? RapidTheme.brandPrimary.opacity(0.35) : RapidTheme.hairline, lineWidth: 1))
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(selection == scene ? .isSelected : [])
                        .accessibilityIdentifier("YouziSimple.Scene.\(scene.rawValue)")
                }
            }.padding(2)
        }.accessibilityIdentifier("YouziSimple.SceneTabs")
    }
}

struct YouziTaskSceneSuggestions: View {
    @Environment(YouziI18nConfig.self) private var i18n
    let scene: YouziTaskScene
    let onSelect: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(scene.prompts(chinese: i18n.isChinese), id: \.self) { prompt in
                Button { onSelect(prompt) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.up.left").font(RapidFont.caption)
                        Text(prompt).font(RapidFont.secondary).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }.foregroundStyle(RapidTheme.textSecondary)
                        .padding(.vertical, 10).padding(.horizontal, 12)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityIdentifier("YouziSimple.SceneSuggestion.\(scene.rawValue).\(prompt)")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
