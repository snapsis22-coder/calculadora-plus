import SwiftUI
import AppKit

// MARK: - Datos

/// Una operación terminada con "=".
struct Operacion: Codable, Identifiable, Hashable {
    var id = UUID()
    let expression: String   // "200 + 10% ="
    let result: String       // "220"
    let date: Date?          // nil = historial de antes de la 1.8.0 (no guardaba la hora)
    var note: String = ""    // "lo que le debo a Luz"
}

/// Todo lo que se hizo en una ventana. Cada ventana tiene su propio archivo JSON
/// en ~/Library/Application Support/Calculadora+/Archivo/.
struct SesionGuardada: Codable {
    let id: UUID
    let opened: Date
    var operations: [Operacion]   // en orden de hora: la más vieja primero
}

// MARK: - Almacén

/// Guarda cada operación en el archivo de su ventana EN EL MOMENTO en que se hace
/// (no al cerrar): así nada se pierde aunque la app se cierre de golpe.
final class ArchiveStore: ObservableObject {
    static let shared = ArchiveStore()

    let folder: URL
    @Published private(set) var sessions: [UUID: SesionGuardada] = [:]
    private var files: [UUID: URL] = [:]

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]   // que se pueda leer a mano
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {
        folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Calculadora+/Archivo", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        migrateOldHistory()
        load()
    }

    // MARK: sesiones (una por ventana)

    /// Una ventana nueva empieza vacía. El archivo se crea con la primera operación.
    func startSession() -> UUID {
        let s = SesionGuardada(id: UUID(), opened: Self.wholeSecond(Date()), operations: [])
        sessions[s.id] = s
        return s.id
    }

    func operations(of session: UUID) -> [Operacion] {
        sessions[session]?.operations ?? []
    }

    func add(expression: String, result: String, to session: UUID) {
        guard sessions[session] != nil else { return }
        sessions[session]!.operations.append(
            Operacion(expression: expression, result: result, date: Self.wholeSecond(Date())))
        save(session)
    }

    /// Pone (o cambia, o quita si viene vacía) la nota de una operación, esté en una
    /// ventana abierta o en el archivo.
    func setNote(_ note: String, for opID: UUID) {
        let clean = note.trimmingCharacters(in: .whitespacesAndNewlines)
        for (sid, s) in sessions {
            if let i = s.operations.firstIndex(where: { $0.id == opID }) {
                sessions[sid]!.operations[i].note = clean
                save(sid)
                return
            }
        }
    }

    func operation(_ id: UUID) -> Operacion? {
        for s in sessions.values {
            if let op = s.operations.first(where: { $0.id == id }) { return op }
        }
        return nil
    }

    // MARK: búsqueda

    struct Grupo: Identifiable {
        let id: String           // título del día
        let ops: [Operacion]     // la más reciente primero
    }

    /// Todas las operaciones agrupadas por día, lo más reciente arriba. La búsqueda
    /// mira la nota, la operación y el resultado, sin importar mayúsculas ni tildes.
    func grupos(buscando texto: String) -> [Grupo] {
        let q = texto.trimmingCharacters(in: .whitespaces)
        let todas = sessions.values.flatMap(\.operations).filter { op in
            q.isEmpty || op.note.localizedStandardContains(q)
                || op.expression.localizedStandardContains(q)
                || op.result.localizedStandardContains(q)
        }
        let conHora = todas.filter { $0.date != nil }.sorted { $0.date! > $1.date! }
        let sinHora = todas.filter { $0.date == nil }

        var grupos: [Grupo] = []
        let cal = Calendar.current
        var dia: Date?
        var actual: [Operacion] = []
        for op in conHora {
            let d = cal.startOfDay(for: op.date!)
            if d != dia {
                if let dia { grupos.append(Grupo(id: Self.dayTitle(dia), ops: actual)) }
                dia = d
                actual = []
            }
            actual.append(op)
        }
        if let dia { grupos.append(Grupo(id: Self.dayTitle(dia), ops: actual)) }
        if !sinHora.isEmpty {
            grupos.append(Grupo(id: "Antes de la versión 1.8.0 (sin hora)", ops: sinHora.reversed()))
        }
        return grupos
    }

    // MARK: archivos

    private func save(_ session: UUID) {
        guard let s = sessions[session], !s.operations.isEmpty else { return }
        let url = files[session] ?? folder.appendingPathComponent(Self.fileName(s))
        files[session] = url
        if let data = try? encoder.encode(s) { try? data.write(to: url, options: .atomic) }
    }

    private func load() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let s = try? decoder.decode(SesionGuardada.self, from: data) else { continue }
            sessions[s.id] = s
            files[s.id] = url
        }
    }

    /// Una sola vez: pasa el historial de la 1.7.0 (guardado en las preferencias) al
    /// archivo. Las preferencias NO se borran. Solo se pasan las que no tienen hora
    /// (las de verdad); las que sí la tienen son pruebas del 7-nov-2026.
    private func migrateOldHistory() {
        let flag = "historialPasadoAlArchivo"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: flag) else { return }
        defer { defaults.set(true, forKey: flag) }

        struct Vieja: Decodable { let expression: String; let result: String; let date: Date? }
        guard let data = defaults.data(forKey: "historial"),
              let viejas = try? JSONDecoder().decode([Vieja].self, from: data) else { return }
        // Venían con la más reciente primero; el archivo va de la más vieja a la más nueva
        let ops = viejas.filter { $0.date == nil }.reversed()
            .map { Operacion(expression: $0.expression, result: $0.result, date: nil) }
        guard !ops.isEmpty else { return }
        let s = SesionGuardada(id: UUID(), opened: Self.wholeSecond(Date()), operations: ops)
        let url = folder.appendingPathComponent("Historial anterior.json")
        if let data = try? encoder.encode(s) { try? data.write(to: url, options: .atomic) }
    }

    // MARK: formatos

    // Hora exacta al segundo (sin fracciones, para que el archivo y la pantalla coincidan)
    private static func wholeSecond(_ d: Date) -> Date {
        Date(timeIntervalSince1970: d.timeIntervalSince1970.rounded(.down))
    }

    // "2026-11-07 15-42-10 (1A2B3C4D).json" — los dos puntos no van en nombres de archivo
    private static func fileName(_ s: SesionGuardada) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return "\(f.string(from: s.opened)) (\(s.id.uuidString.prefix(8))).json"
    }

    static func dayTitle(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_CO")
        f.dateStyle = .full                // "sábado, 7 de noviembre de 2026"
        f.timeStyle = .none
        let t = f.string(from: d)
        return t.prefix(1).uppercased() + t.dropFirst()
    }

    static func timeText(_ d: Date?) -> String {
        guard let d else { return "—" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_CO")
        f.dateFormat = "h:mm:ss a"         // "3:42:10 p. m."
        return f.string(from: d)
    }
}

// MARK: - Editor de nota (se usa en la calculadora y en el archivo)

struct NoteEditor: View {
    let op: Operacion
    let onDone: () -> Void
    @State private var text: String
    @FocusState private var focused: Bool

    init(op: Operacion, onDone: @escaping () -> Void) {
        self.op = op
        self.onDone = onDone
        _text = State(initialValue: op.note)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nota para  \(op.expression) \(op.result)")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            TextField("¿Para qué fue este cálculo?", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .focused($focused)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancelar", action: onDone).keyboardShortcut(.cancelAction)
                Button("Guardar", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .onAppear { focused = true }
    }

    private func save() {
        ArchiveStore.shared.setNote(text, for: op.id)
        onDone()
    }
}

// MARK: - Ventana del archivo

struct ArchiveView: View {
    @ObservedObject private var store = ArchiveStore.shared
    @State private var search = ""
    @State private var editing: UUID?

    var body: some View {
        let grupos = store.grupos(buscando: search)
        Group {
            if grupos.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: search.isEmpty ? "archivebox" : "magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)
                    Text(search.isEmpty ? "Todavía no hay operaciones archivadas"
                                        : "Nada coincide con «\(search)»")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(grupos) { g in
                        Section(g.id) {
                            ForEach(g.ops) { op in row(op) }
                        }
                    }
                }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Buscar nota, número u operación")
        .toolbar {
            Button { NSWorkspace.shared.open(store.folder) } label: {
                Label("Mostrar en el Finder", systemImage: "folder")
            }
            .help("Abrir la carpeta donde se guardan los archivos")
        }
        .frame(minWidth: 460, minHeight: 420)
    }

    private func row(_ op: Operacion) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(ArchiveStore.timeText(op.date))
                .font(.system(size: 12).monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 92, alignment: .leading)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                if !op.note.isEmpty {
                    Label(op.note, systemImage: "tag.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.orange)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(op.expression)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Text(op.result)
                    .font(.system(size: 18, weight: .light))
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copiar resultado") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(op.result, forType: .string)
            }
            Button(op.note.isEmpty ? "Ponerle nota…" : "Editar nota…") { editing = op.id }
        }
        .popover(isPresented: Binding(get: { editing == op.id },
                                      set: { if !$0 { editing = nil } })) {
            NoteEditor(op: op) { editing = nil }
        }
    }
}
