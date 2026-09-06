import Foundation
import Observation
import SwiftUI

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system = "system"
    case zhHans = "zh-Hans"
    case en = "en"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .zhHans: return "简体中文"
        case .en: return "English"
        }
    }

    public func localizedDisplayName(isChinese: Bool) -> String {
        if isChinese {
            return displayName
        }
        switch self {
        case .system: return "System Default"
        case .zhHans: return "Simplified Chinese"
        case .en: return "English"
        }
    }

    public var accessibilityIdentifier: String {
        "Settings.Appearance.Language.\(rawValue)"
    }
}

@MainActor
@Observable
public final class YouziI18nConfig {
    public static let shared = YouziI18nConfig()
    public static let storageKey = "rapid.language.v1"

    private let defaults: UserDefaults

    public var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Self.storageKey)
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.string(forKey: Self.storageKey),
           let saved = AppLanguage(rawValue: raw) {
            self.language = saved
        } else {
            self.language = .system
        }
    }

    public var isChinese: Bool {
        switch language {
        case .zhHans:
            return true
        case .en:
            return false
        case .system:
            if let preferred = Locale.preferredLanguages.first {
                return preferred.hasPrefix("zh")
            }
            return Locale.current.language.languageCode?.identifier == "zh"
        }
    }

    public var locale: Locale {
        switch language {
        case .system:
            return Locale.autoupdatingCurrent
        case .zhHans:
            return Locale(identifier: "zh-Hans")
        case .en:
            return Locale(identifier: "en")
        }
    }

    public func text(zh: String, en: String) -> String {
        isChinese ? zh : en
    }

    public func callAsFunction(zh: String, en: String) -> String {
        text(zh: zh, en: en)
    }
}

/// Central localization lookup dictionary for standard terms, Settings titles,
/// and common system copy to prevent mixed Chinese/English across views.
public enum YouziLocalization {
    private static let zhToEn: [String: String] = [
        "数据管理": "Data Management",
        "安全中心": "Security Center",
        // My Files & Tasks
        "我的文件": "My Files",
        "本地产物": "Local Deliverables",
        "全部类型": "All Types",
        "幻灯片": "Presentation",
        "网站": "Web",
        "更新人": "Updated by",
        "更新时间": "Updated at",
        "大小": "Size",
        "名称": "Name",
        "类型": "Type",
        "我的收藏": "Favorites",
        "已收藏": "Favorited",
        "未分组": "Ungrouped",
        "本地任务": "Local Task",
        "任务": "Tasks",
        "列表模式": "List View",
        "预览模式": "Preview Mode",
        "添加自定义专家": "Add Custom Expert",
        "新建专家": "New Expert",
        "专家名称": "Expert Name",
        "专家简介": "Expert Summary",
        "工作方法/指令": "Instructions / Methodology",
        "配置连接器": "Configure Connector",
        "添加连接器": "Add Connector",
        "连接器名称": "Connector Name",
        "连接命令或地址": "Command or URL",
        "重命名任务": "Rename Task",
        "任务名称": "Task Name",

        // Settings Categories
        "通用": "General",
        "个性化": "Personalization",
        "记忆": "Memory",
        "智能体": "Agents",
        "模型": "Models",
        "数据与安全": "Data & Privacy",
        "关于": "About",
        "连接器": "Connectors",
        "性能": "Performance",
        "实验功能": "Experimental",
        "开发者": "Developer",

        // Settings Section Groups
        "设置": "Settings",
        "功能": "Features",

        // Appearance
        "外观": "Appearance",
        "外观主题": "Theme",
        "系统明暗": "Theme",
        "深浅色": "Theme",
        "语言": "Language",
        "选择语言": "Language",
        "跟随系统": "System Default",
        "简体中文": "Simplified Chinese",
        "自动": "Auto",
        "浅色": "Light",
        "深色": "Dark",

        // Common Actions
        "确定": "OK",
        "取消": "Cancel",
        "保存": "Save",
        "删除": "Delete",
        "重命名": "Rename",
        "重试": "Retry",
        "下载": "Download",
        "完成": "Done",
        "编辑": "Edit",
        "清空": "Clear",
        "清空全部": "Clear All",
        "移至文件夹": "Move to Folder",
        "移出文件夹": "Remove from Folder",
        "新建文件夹": "New Folder",
        "在 Finder 中显示": "Reveal in Finder",
        "导出": "Export",
        "导出副本…": "Export Copy…",
        "预览": "Preview",
        "检查更新": "Check for Updates",
        "帮助与反馈": "Help & Feedback",
        "收起": "Collapse",
        "展开": "Expand",
        "关闭": "Close",

        // Navigation & Workspace
        "新任务": "New Task",
        "工作空间": "Workspaces",
        "专家·技能·连接": "Experts · Skills · Connectors",
        "知我": "About Me",
        "成果": "Deliverables",
        "最近任务": "Recent Tasks",
        "对话文件夹": "Chat Folders",
        "未命名任务": "Untitled Task",
        "系统状态": "System Status",
        "本机单机运行": "Runs 100% locally on your Mac",

        // Status & Tabs
        "专家": "Experts",
        "技能": "Skills",
        "连接": "Connectors",
        "常用": "Frequently Used",
        "已下载": "On disk",
        "运行中": "In use",
        "未下载": "Not cached",
        "失败": "Failed",
        "暂无已下载模型": "No downloaded models",
        "更多模型设置…": "More Model Settings…",

        // Rows in Settings
        "关闭窗口时隐藏 Dock 图标": "Hide Dock icon when closing window",
        "启用视频生成": "Enable video generation",
        "全局默认": "Global default",
        "自动记忆": "Automatic memory",
        // Connectors & Memory
        "服务": "Servers",
        "权限与授权": "Approvals",
        "工作空间与项目": "Workspaces & Projects",
        "文件夹": "Folders",
        "项目": "Projects",
        "开源智能体推荐": "Recommended Open-Source Agents",
        "开源技能推荐": "Recommended Open-Source Skills",
        "开源 MCP 连接推荐": "Recommended MCP Connectors",
        "查看": "View",
        "新建文件夹并移动…": "Move to New Folder…",
        "取消置顶": "Unpin",
        "置顶": "Pin",
        "取消归档": "Unarchive",
        "归档": "Archive",
        "简约模式": "Simple Mode",
        "专业模式": "Professional Mode",
        "场景模型选择": "Scenario Models",
        "聊天": "Chat",
        "图形": "Images",
        "语音": "Audio",
        "视频": "Video",
        "已关闭": "Turned off",
        "已连接": "Connected",
        "正在连接…": "Connecting…",
        "未连接": "Not connected",
        "始终允许": "always allowed",
        "自动授权所有工具调用": "Auto-approve all tool calls",
        "启用连接器": "Enable connectors",
    ]

    private static let enToZh: [String: String] = [
        "Data Management": "数据管理",
        "Security Center": "安全中心",
        // My Files & Tasks
        "My Files": "我的文件",
        "Local Deliverables": "本地产物",
        "All Types": "全部类型",
        "Presentation": "幻灯片",
        "Web": "网站",
        "Updated by": "更新人",
        "Updated at": "更新时间",
        "Size": "大小",
        "Name": "名称",
        "Type": "类型",
        "Favorites": "我的收藏",
        "Favorited": "已收藏",
        "Ungrouped": "未分组",
        "Local Task": "本地任务",
        "Tasks": "任务",
        "List View": "列表模式",
        "Preview Mode": "预览模式",
        "Add Custom Expert": "添加自定义专家",
        "New Expert": "新建专家",
        "Expert Name": "专家名称",
        "Expert Summary": "专家简介",
        "Instructions / Methodology": "工作方法/指令",
        "Configure Connector": "配置连接器",
        "Add Connector": "添加连接器",
        "Connector Name": "连接器名称",
        "Command or URL": "连接命令或地址",
        "Rename Task": "重命名任务",
        "Task Name": "任务名称",

        "New Chat": "新对话",
        "Images": "图片",
        "Audio": "语音",
        "Video": "视频",
        "Launch": "启动",
        "Pinned": "置顶",
        "Today": "今天",
        "Yesterday": "昨天",
        "Previous 7 Days": "过去 7 天",
        "Older": "更早",
        "Archived": "归档",
        "Delete": "删除",
        "Keep": "保留",
        "Save": "保存",
        "Cancel": "取消",
        "Rename": "重命名",
        "Unarchive": "取消归档",
        "Archive": "归档",
        "Export Markdown…": "导出 Markdown…",
        "Export JSON…": "导出 JSON…",
        "Move to Folder": "移至文件夹",
        "Remove from Folder": "移出文件夹",
        "New Folder…": "新建文件夹…",
        "Delete Folder": "删除文件夹",
        "General": "通用",
        "Theme": "外观主题",
        "Appearance": "外观",
        "Language": "语言",
        "Models": "模型",
        "Personalization": "个性化",
        "Memory": "记忆",
        "Agents": "智能体",
        "Tools": "工具与智能体",
        "Data & Privacy": "数据与安全",
        "About": "关于",
        "Connectors": "连接器",
        "Performance": "性能",
        "Experimental": "实验功能",
        "Settings": "设置",
        "Features": "功能",
        "Web search": "联网搜索",
        "Browsing": "网页浏览",
        "Available tools": "可用工具",
        "Models folder": "模型存储目录",
        "Linked models": "已链接模型",
        "Preferences": "偏好设置",
        "Disk overview": "磁盘占用概览",
        "Version": "版本",
        "Installed": "已安装版本",
        "Latest release": "最新可用版本",
        "Updates": "应用更新",
        "Automatically download updates": "自动下载更新",
        "Check for Updates": "检查更新",
        "Diagnostics": "诊断信息",
        "Show Server Log": "查看服务日志",
        "Reset Setup": "重置初始化",
        "Send anonymous usage data": "发送匿名使用数据",
        "Where the data goes": "数据去向",
        "Privacy policy": "隐私政策",
        "Open-source credits": "开源许可与声明",
        "License (EULA)": "最终用户许可协议",
        "Servers": "服务",
        "Approvals": "权限与授权",
        "Workspaces & Projects": "工作空间与项目",
        "Folders": "文件夹",
        "Projects": "项目",
        "Recommended Open-Source Agents": "开源智能体推荐",
        "Recommended Open-Source Skills": "开源技能推荐",
        "Recommended MCP Connectors": "开源 MCP 连接推荐",
        "View": "查看",
        "Move to New Folder…": "新建文件夹并移动…",
        "Unpin": "取消置顶",
        "Pin": "置顶",
        "Simple Mode": "简约模式",
        "Professional Mode": "专业模式",
        "Scenario Models": "场景模型选择",
        "Chat": "聊天",
        "Turned off": "已关闭",
        "Connected": "已连接",
        "Connecting…": "正在连接…",
        "Not connected": "未连接",
        "always allowed": "始终允许",
        "Auto-approve all tool calls": "自动授权所有工具调用",
        "Enable connectors": "启用连接器",
    ]

    public static func english(for chinese: String) -> String {
        zhToEn[chinese] ?? chinese
    }

    public static func chinese(for english: String) -> String {
        enToZh[english] ?? english
    }

    public static func localized(_ text: String, isChinese: Bool) -> String {
        if isChinese {
            return enToZh[text] ?? text
        } else {
            return zhToEn[text] ?? text
        }
    }
}
