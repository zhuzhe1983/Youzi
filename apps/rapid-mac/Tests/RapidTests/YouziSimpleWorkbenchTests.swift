import Foundation
import Testing
@testable import Rapid

@Suite("YouziSimpleWorkbench")
struct YouziSimpleWorkbenchTests {
    @Test("Bundled templates are versioned, unique, and editable-draft inputs")
    func bundledTemplateCatalog() throws {
        let catalog = try YouziBundledTemplateCatalog.loadBundled()

        #expect(catalog.schemaVersion == 1)
        #expect(catalog.catalogVersion == "1.0.0")
        #expect(catalog.templates.count == 4)
        #expect(Set(catalog.templates.map(\.id)).count == catalog.templates.count)
        #expect(Set(catalog.templates.map(\.category)).count >= 3)
        #expect(catalog.templates.allSatisfy { !$0.prefilledRequest.isEmpty })
        #expect(catalog.templates.allSatisfy { !$0.requiredInputs.isEmpty })
    }

    @Test("Unsupported template schemas fail closed")
    func unsupportedTemplateSchema() {
        let catalog = YouziBundledTemplateCatalog(
            schemaVersion: 2,
            catalogVersion: "2.0.0",
            templates: []
        )

        #expect(throws: YouziBundledTemplateCatalog.LoadError.unsupportedSchemaVersion(2)) {
            try catalog.validate()
        }
    }

    @Test("Duplicate template identity is rejected")
    func duplicateTemplateIdentity() {
        let id = UUID()
        let entry = YouziBundledTemplateCatalog.Entry(
            id: id,
            name: "模板",
            category: "资料整理",
            summary: "说明",
            samplePreview: "示例成果",
            prefilledRequest: "可编辑请求",
            requiredInputs: ["补充资料"]
        )
        let catalog = YouziBundledTemplateCatalog(
            schemaVersion: 1,
            catalogVersion: "1.0.0",
            templates: [entry, entry]
        )

        #expect(throws: YouziBundledTemplateCatalog.LoadError.duplicateTemplateID(id)) {
            try catalog.validate()
        }
    }

    @Test("Template gallery creates an editable draft without an execution path")
    func templateGalleryOnlyCreatesDrafts() throws {
        let source = try sourceFile("YouziSimpleTemplateGallery.swift")

        #expect(source.contains("let onCreateDraft:"))
        #expect(source.contains("onCreateDraft(entry)"))
        #expect(source.contains("创建可编辑草稿"))
        #expect(!source.contains("chat.send"))
        #expect(!source.contains("submit()"))
        #expect(!source.contains("autoExecute"))
    }

    @Test("Results present artifacts and delegate every filesystem action")
    func resultsUseArtifactsNotConversations() throws {
        let source = try sourceFile("YouziSimpleResultsPage.swift")

        #expect(source.contains("let artifacts: [YouziArtifact]"))
        #expect(source.contains("(YouziArtifact) -> YouziFile?"))
        #expect(source.contains("let onPreview:"))
        #expect(source.contains("let onRevealInFinder:"))
        #expect(source.contains("let onExport:"))
        #expect(!source.contains("Conversation"))
        #expect(!source.contains("FileManager"))
        #expect(!source.contains("NSWorkspace"))
        #expect(source.contains("Text(\"成果\")"))
        #expect(source.contains("还没有任务成果"))
        #expect(!source.contains("任务结果"))
    }

    @Test("Simple workbench binds only the app-owned product model")
    func oneProductModelEnvironment() throws {
        let shell = try sourceFile("YouziSimpleShell.swift")
        let task = try sourceFile("YouziSimpleTaskView.swift")
        let pages = try sourceFile("YouziSimpleDomainPages.swift")

        #expect(shell.contains("@Environment(YouziProductModel.self)"))
        #expect(task.contains("@Environment(YouziProductModel.self)"))
        #expect(!shell.contains("YouziProductModel("))
        #expect(!task.contains("YouziProductModel("))
        #expect(!pages.contains("YouziProductModel("))
        #expect(!shell.contains("YouziDomainStore("))
        #expect(!task.contains("YouziDomainStore("))
    }

    @Test("Every Simple destination reads canonical domain records")
    func destinationsUseDomainRecords() throws {
        let shell = try sourceFile("YouziSimpleShell.swift")
        let pages = try sourceFile("YouziSimpleDomainPages.swift")

        for projection in [
            "productModel.tasks",
            "productModel.workspaces",
            "productModel.projects",
            "productModel.artifacts",
            "productModel.document.helpers",
            "productModel.document.memoryNodes",
        ] {
            #expect(shell.contains(projection))
        }
        #expect(pages.contains("let workspaces: [YouziWorkspace]"))
        #expect(pages.contains("let projects: [YouziProject]"))
        #expect(pages.contains("let files: [YouziFile]"))
        #expect(shell.contains("sidebarLabel(\"对话文件夹\")"))
    }

    @Test("Task submission links lifecycle before the shared chat runtime sends")
    func taskExecutionOrdering() throws {
        let task = try sourceFile("YouziSimpleTaskView.swift")
        let begin = try #require(task.range(of: "productModel.beginTaskExecution("))
        let send = try #require(task.range(of: "chat.send(request"))

        #expect(begin.lowerBound < send.lowerBound)
        #expect(task.contains("productModel.assignWorkspace("))
        #expect(task.contains("productModel.moveTask("))
        #expect(task.contains("mode: .copy"))
        #expect(task.contains("mode: .reference"))
        #expect(task.contains("productModel.importFile("))
        #expect(task.contains("productModel.referenceProjectFile("))
        #expect(task.contains("fileAttachments: attachments"))
    }

    @Test("Bundled templates seed once and instantiate editable drafts")
    func templatePersistenceWiring() throws {
        let shell = try sourceFile("YouziSimpleShell.swift")
        let package = try String(
            contentsOf: packageRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )

        #expect(shell.contains("productModel.seedTemplates(templates)"))
        #expect(shell.contains("productModel.instantiateTemplate(id: entry.id)"))
        #expect(shell.contains("if !isCurrent"))
        #expect(package.contains(".process(\"Resources/youzi-templates-v1.json\")"))
    }

    @Test("Artifact actions use closure-scoped resolution and model export")
    func artifactFileActions() throws {
        let shell = try sourceFile("YouziSimpleShell.swift")

        #expect(shell.contains("productModel.file(for: artifact)"))
        #expect(shell.contains("productModel.withFileURL(id: artifact.fileID)"))
        #expect(shell.contains("productModel.exportFile(id: artifact.fileID"))
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func sourceFile(_ name: String) throws -> String {
        let file = packageRoot
            .appendingPathComponent("Sources/Rapid/UI/YouziSimple")
            .appendingPathComponent(name)
        return try String(contentsOf: file, encoding: .utf8)
    }
}
