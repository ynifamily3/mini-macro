import AppKit
import Combine
import MacroCore

struct RecordingEditorRequest: Identifiable { let id: UUID }

@MainActor
final class AutomationStore: ObservableObject {
    @Published private(set) var macros: [SavedMacro] = []
    @Published private(set) var workflows: [AutomationWorkflow] = []
    @Published var error: String?
    @Published var recordingEditor: RecordingEditorRequest?
    private var pendingSaves: [UUID: Task<Void, Never>] = [:]
    let root: URL

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MouseMacro")
        do {
            for folder in ["Macros", "Automations"] {
                try FileManager.default.createDirectory(at: self.root.appendingPathComponent(folder), withIntermediateDirectories: true)
            }
            for url in try FileManager.default.contentsOfDirectory(at: self.root.appendingPathComponent("Macros"), includingPropertiesForKeys: [.fileSizeKey]) where url.pathExtension == "json" {
                do {
                    let item = try JSONDecoder().decode(SavedMacro.self, from: Self.read(url, limit: 80_000_000))
                    _ = try item.recording.validated()
                    guard url.deletingPathExtension().lastPathComponent == item.id.uuidString else { throw RecordingError.invalidRecording }
                    macros.append(item)
                } catch { self.error = "일부 매크로를 읽지 못했습니다. 원본 파일은 유지했습니다: \(url.lastPathComponent)" }
            }
            for url in try FileManager.default.contentsOfDirectory(at: self.root.appendingPathComponent("Automations"), includingPropertiesForKeys: [.fileSizeKey]) where url.pathExtension == "json" {
                do {
                    let original = try Self.read(url, limit: 100_000_000)
                    var workflow = try JSONDecoder().decode(AutomationWorkflow.self, from: original)
                    guard url.deletingPathExtension().lastPathComponent == workflow.id.uuidString else { throw RecordingError.invalidRecording }
                    if workflow.graph == nil {
                        workflow.graph = try AutomationGraph.migrating(workflow.steps)
                        workflow.steps = []
                        let backup = url.appendingPathExtension("v2-backup")
                        if !FileManager.default.fileExists(atPath: backup.path) { try original.write(to: backup, options: .atomic) }
                        try write(workflow, to: url)
                    }
                    try workflow.graph?.validateStructure()
                    workflows.append(workflow)
                } catch { self.error = "일부 자동화를 읽지 못했습니다. 원본 파일은 유지했습니다: \(url.lastPathComponent)" }
            }
            macros.sort { $0.recording.createdAt > $1.recording.createdAt }
            workflows.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let legacy = self.root.appendingPathComponent("last-recording.json")
            if macros.isEmpty, FileManager.default.fileExists(atPath: legacy.path) {
                let recording = try JSONDecoder().decode(MacroRecording.self, from: Self.read(legacy, limit: 80_000_000)).validated()
                addRecording(recording, name: "이전 녹화")
            }
        } catch { self.error = "보관함을 열 수 없습니다: \(error.localizedDescription)" }
    }

    private static func read(_ url: URL, limit: Int) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? limit
        guard size <= limit else { throw RecordingError.invalidRecording }
        return try Data(contentsOf: url)
    }

    private func url(for id: UUID, folder: String) -> URL {
        root.appendingPathComponent(folder).appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    @discardableResult
    func addRecording(_ recording: MacroRecording, name: String? = nil) -> UUID? {
        if let existing = macros.first(where: { $0.recording == recording }) { return existing.id }
        let item = SavedMacro(name: name ?? "녹화 \(Date().formatted(date: .abbreviated, time: .shortened))", recording: recording)
        do {
            _ = try recording.validated()
            try write(item, to: url(for: item.id, folder: "Macros"))
            macros.insert(item, at: 0)
            return item.id
        } catch { self.error = "매크로 보관함 저장에 실패했습니다: \(error.localizedDescription)"; return nil }
    }

    func renameMacro(_ id: UUID, name: String) {
        guard let i = macros.firstIndex(where: { $0.id == id }) else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var item = macros[i]; item.name = String(name.prefix(100))
        do { try write(item, to: url(for: id, folder: "Macros")); macros[i] = item }
        catch { self.error = error.localizedDescription }
    }

    /// Preserve the macro ID so automation nodes keep pointing to the edited recording.
    @discardableResult
    func saveEditedMacro(_ item: SavedMacro, replacing original: SavedMacro?) throws -> SavedMacro {
        if let original {
            guard item.id == original.id, macros.first(where: { $0.id == original.id }) == original else {
                throw AutomationError.invalid("다른 창에서 이 매크로가 변경되었거나 삭제되었습니다. 편집기를 다시 열어주세요.")
            }
        } else if macros.contains(where: { $0.id == item.id }) {
            throw AutomationError.invalid("같은 매크로가 이미 저장되어 있습니다. 편집기를 다시 열어주세요.")
        }
        var value = item
        value.name = String(value.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        guard !value.name.isEmpty else { throw AutomationError.invalid("매크로 이름을 입력해주세요.") }
        _ = try value.recording.validated()
        try write(value, to: url(for: value.id, folder: "Macros"))
        if let index = macros.firstIndex(where: { $0.id == value.id }) { macros[index] = value }
        else { macros.insert(value, at: 0) }
        return value
    }

    @discardableResult
    func createWorkflow() -> UUID {
        var workflow = AutomationWorkflow(name: "새 자동화 \(workflows.count + 1)")
        workflow.graph = AutomationGraph.draft()
        workflows.append(workflow)
        save(workflow)
        return workflow.id
    }

    func update(_ value: AutomationWorkflow) {
        var workflow = value
        do {
            if workflow.graph == nil { workflow.graph = try AutomationGraph.migrating(workflow.steps) }
            workflow.steps = []
            try workflow.graph?.validateStructure()
        } catch { self.error = error.localizedDescription; return }
        guard let index = workflows.firstIndex(where: { $0.id == workflow.id }) else { return }
        workflows[index] = workflow
        pendingSaves[workflow.id]?.cancel()
        pendingSaves[workflow.id] = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            guard let self else { return }
            self.save(workflow)
            self.pendingSaves[workflow.id] = nil
        }
    }

    func flush() {
        for task in pendingSaves.values { task.cancel() }
        let ids = Set(pendingSaves.keys)
        pendingSaves.removeAll()
        for workflow in workflows where ids.contains(workflow.id) { save(workflow) }
    }

    private func save(_ workflow: AutomationWorkflow) {
        do { try write(workflow, to: url(for: workflow.id, folder: "Automations")) }
        catch { self.error = "자동화를 저장하지 못했습니다: \(error.localizedDescription)" }
    }

    func deleteMacro(_ id: UUID) {
        if let workflow = workflows.first(where: { $0.referencedMacroIDs.contains(id) }) {
            error = "‘\(workflow.name)’에서 사용하는 매크로입니다. 자동화에서 해당 단계를 먼저 제거해주세요."
            return
        }
        recycle(url(for: id, folder: "Macros")) { [weak self] in self?.macros.removeAll { $0.id == id } }
    }

    func deleteWorkflow(_ id: UUID) {
        flush()
        recycle(url(for: id, folder: "Automations")) { [weak self] in self?.workflows.removeAll { $0.id == id } }
    }

    private func recycle(_ url: URL, completion: @escaping @MainActor () -> Void) {
        NSWorkspace.shared.recycle([url]) { [weak self] _, error in
            Task { @MainActor in
                if let error { self?.error = error.localizedDescription }
                else { completion() }
            }
        }
    }
}
