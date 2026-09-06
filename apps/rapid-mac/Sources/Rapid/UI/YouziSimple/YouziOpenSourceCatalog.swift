import Foundation

/// Curated, display-only catalogs of open-source agents, skills, and MCP
/// servers. These are discovery lists, not installed records: selecting an
/// unconfigured connector never writes an account id onto a task.
enum YouziOpenSourceCatalog: Sendable {
    struct Item: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let summary: String
        let url: URL?
    }

    static let agents: [Item] = [
        Item(
            id: "open-interpreter",
            name: "Open Interpreter",
            summary: "在本机运行的开源电脑代理，适合把自然语言变成可检查的本地操作。",
            url: URL(string: "https://github.com/openinterpreter/open-interpreter")
        ),
        Item(
            id: "autogen",
            name: "AutoGen",
            summary: "微软开源的多专家协作框架，适合把复杂任务拆给一组角色。",
            url: URL(string: "https://github.com/microsoft/autogen")
        ),
        Item(
            id: "crewai",
            name: "CrewAI",
            summary: "轻量的角色与任务编排，适合把研究、写作和检查分成明确步骤。",
            url: URL(string: "https://github.com/crewAIInc/crewAI")
        ),
        Item(
            id: "langgraph",
            name: "LangGraph",
            summary: "有状态的图编排，适合需要循环、分支和人工确认的长任务。",
            url: URL(string: "https://github.com/langchain-ai/langgraph")
        ),
        Item(
            id: "swe-agent",
            name: "SWE-agent",
            summary: "面向代码仓库的开源软件工程代理。",
            url: URL(string: "https://github.com/SWE-agent/SWE-agent")
        ),
    ]

    static let skills: [Item] = [
        Item(
            id: "anthropic-skills",
            name: "Anthropic Skills",
            summary: "可分享的技能包格式，适合把可复用工作方式写成文档和脚本。",
            url: URL(string: "https://github.com/anthropics/skills")
        ),
        Item(
            id: "codex-skills",
            name: "Codex Skills",
            summary: "面向本地代理的技能目录，适合安装文档、浏览器和发布类能力。",
            url: URL(string: "https://github.com/openai/codex")
        ),
        Item(
            id: "awesome-llm-apps",
            name: "Awesome LLM Apps",
            summary: "开源智能体与技能示例合集，适合找可落地的工作流。",
            url: URL(string: "https://github.com/Shubhamsaboo/awesome-llm-apps")
        ),
    ]

    static let mcpServers: [Item] = [
        Item(
            id: "mcp-filesystem",
            name: "Filesystem",
            summary: "官方文件系统 MCP，适合受控地读写本地文件夹。",
            url: URL(string: "https://github.com/modelcontextprotocol/servers")
        ),
        Item(
            id: "mcp-github",
            name: "GitHub",
            summary: "仓库、议题和拉取请求的 MCP 连接器。",
            url: URL(string: "https://github.com/modelcontextprotocol/servers")
        ),
        Item(
            id: "mcp-fetch",
            name: "Fetch",
            summary: "抓取网页正文，适合给研究任务补充公开资料。",
            url: URL(string: "https://github.com/modelcontextprotocol/servers")
        ),
        Item(
            id: "mcp-sqlite",
            name: "SQLite",
            summary: "查询本地 SQLite 数据库。",
            url: URL(string: "https://github.com/modelcontextprotocol/servers")
        ),
        Item(
            id: "mcp-memory",
            name: "Memory",
            summary: "轻量知识图谱记忆，适合跨任务记住已确认的事实。",
            url: URL(string: "https://github.com/modelcontextprotocol/servers")
        ),
        Item(
            id: "mcp-puppeteer",
            name: "Puppeteer",
            summary: "浏览器自动化 MCP，适合需要实际打开页面的任务。",
            url: URL(string: "https://github.com/modelcontextprotocol/servers")
        ),
    ]
}
