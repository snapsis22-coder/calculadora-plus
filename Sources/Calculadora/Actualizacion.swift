import AppKit
import CryptoKit
import SwiftUI

// Actualización desde las Releases de GitHub. El mismo archivo vive en cada app
// (SubFix, Triturador, Calculadora+, Peek a Boo); sólo cambian estas dos líneas.
enum ConfigDeActualizacion {
    static let repositorio = "snapsis22-coder/calculadora-plus"
    /// Cómo se llama el .app dentro del DMG.
    static let app = "Calculadora+"
    /// Repo privado: se consulta y se baja con `gh` y la sesión de GitHub del Mac,
    /// sin guardar ninguna clave dentro de la app.
    static let privado = false
}

/// Busca al abrir (como mucho una vez cada 20 h) o desde el menú, y avisa en una ventanita.
/// Sólo instala cuando el usuario pulsa «Actualizar», y no mientras la app está ocupada.
///
/// La confianza se apoya en dos cosas: el SHA-256 que publica GitHub y que la app nueva
/// esté firmada con **el mismo certificado** que la instalada. Como la descarga la hace la
/// app y no el navegador, la versión nueva no lleva la marca de «descargado de internet» y
/// macOS no vuelve a pedir «Abrir de todos modos».
@MainActor
final class Actualizaciones: ObservableObject {

    static let compartido = Actualizaciones()

    struct Version: Equatable, Sendable {
        let numero: String
        let etiqueta: String
        let notas: String
        let dmg: URL
        let sha256: String?
    }

    enum Estado: Equatable {
        case quieto, buscando, alDia
        case disponible(Version)
        case descargando(Version, Double)
        case instalando(Version)
        case fallo(String)
    }

    @Published private(set) var estado = Estado.quieto
    @Published var buscarSola = UserDefaults.standard.object(forKey: "actualizar.alAbrir") as? Bool ?? true {
        didSet { UserDefaults.standard.set(buscarSola, forKey: "actualizar.alAbrir") }
    }
    /// La app dice aquí si está a mitad de algo que no se debe cortar.
    var ocupada: () -> Bool = { false }

    private var ventana: NSPanel?

    /// `ACTUALIZAR_VERSION_FINGIDA=1.0` hace creer a la app que es vieja, para probar.
    static var versionActual: String {
        ProcessInfo.processInfo.environment["ACTUALIZAR_VERSION_FINGIDA"]
            ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // MARK: Buscar

    /// Se llama al arrancar la app.
    func arrancar() {
        guard buscarSola else { return }
        let ultima = UserDefaults.standard.object(forKey: "actualizar.ultima") as? Date ?? .distantPast
        guard Date().timeIntervalSince(ultima) > 20 * 3600 else { return }
        Task {
            try? await Task.sleep(for: .seconds(4))      // que la ventana principal salga primero
            await buscar(aMano: false)
        }
    }

    func buscar(aMano: Bool) async {
        switch estado {
        case .buscando, .descargando, .instalando: return
        default: break
        }
        estado = .buscando
        do {
            let nueva = try await Self.consultarGitHub()
            UserDefaults.standard.set(Date(), forKey: "actualizar.ultima")
            let omitida = UserDefaults.standard.string(forKey: "actualizar.omitida")
            if let nueva, aMano || nueva.numero != omitida {
                estado = .disponible(nueva)
                mostrar()
            } else {
                estado = aMano ? .alDia : .quieto
                if aMano { mostrar() }
            }
        } catch {
            estado = aMano ? .fallo(error.localizedDescription) : .quieto
            if aMano { mostrar() }
        }
    }

    func omitir() {
        if case .disponible(let v) = estado { UserDefaults.standard.set(v.numero, forKey: "actualizar.omitida") }
        cerrar()
    }

    func cerrar() {
        estado = .quieto
        ventana?.close()
        ventana = nil
    }

    // MARK: Instalar

    func actualizar() async {
        guard case .disponible(let version) = estado, !ocupada() else { return }
        let instalada = Bundle.main.bundleURL
        if instalada.path.hasPrefix("/Volumes/") {
            estado = .fallo("La app se está abriendo desde el DMG. Arrástrala a Aplicaciones y actualiza desde ahí.")
            return
        }
        estado = .descargando(version, 0)
        do {
            let dmg = try await Self.descargar(version) { avance in
                Task { @MainActor in
                    if case .descargando = self.estado { self.estado = .descargando(version, avance) }
                }
            }
            estado = .instalando(version)
            try await Task.detached {
                let nueva = try Self.preparar(dmg: dmg, version: version.numero, contra: instalada)
                try Self.instalar(nueva, en: instalada)
            }.value
            Self.relanzar(instalada)
        } catch {
            estado = .fallo(error.localizedDescription)
        }
    }

    // MARK: - Motor (fuera del hilo principal)

    struct Fallo: LocalizedError {
        let detalle: String
        var errorDescription: String? { detalle }
    }

    nonisolated static func esMasNueva(_ candidata: String, que actual: String) -> Bool {
        func partes(_ texto: String) -> [Int] {
            var limpio = texto.trimmingCharacters(in: .whitespaces)
            if limpio.lowercased().hasPrefix("v") { limpio.removeFirst() }
            limpio = String(limpio.split(separator: "-").first ?? "")
            return limpio.split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = partes(candidata), b = partes(actual)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private struct Publicacion: Decodable {
        struct Archivo: Decodable { let name: String; let browser_download_url: URL; let digest: String? }
        let tag_name: String
        let body: String?
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Archivo]
    }

    nonisolated static func interpretar(_ datos: Data, actual: String) throws -> Version? {
        let p = try JSONDecoder().decode(Publicacion.self, from: datos)
        guard p.draft != true, p.prerelease != true, esMasNueva(p.tag_name, que: actual),
              let dmg = p.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) else { return nil }
        var hash = dmg.digest?.lowercased()
        if let h = hash, h.hasPrefix("sha256:") { hash = String(h.dropFirst(7)) } else { hash = nil }
        var numero = p.tag_name
        if numero.lowercased().hasPrefix("v") { numero.removeFirst() }
        return Version(numero: numero, etiqueta: p.tag_name, notas: p.body ?? "",
                       dmg: dmg.browser_download_url, sha256: hash)
    }

    nonisolated static func consultarGitHub() async throws -> Version? {
        let actual = await MainActor.run { versionActual }
        if ConfigDeActualizacion.privado {
            let salida = try correr(try rutaDeGh(), ["api", "repos/\(ConfigDeActualizacion.repositorio)/releases/latest"])
            guard salida.codigo == 0 else {
                throw Fallo(detalle: "gh no pudo consultar GitHub (¿sesión iniciada? corre «gh auth status»)")
            }
            return try interpretar(Data(salida.texto.utf8), actual: actual)
        }
        var peticion = URLRequest(url: URL(string:
            "https://api.github.com/repos/\(ConfigDeActualizacion.repositorio)/releases/latest")!)
        peticion.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        peticion.setValue("\(ConfigDeActualizacion.app)/\(actual)", forHTTPHeaderField: "User-Agent")
        peticion.timeoutInterval = 15
        let (datos, respuesta) = try await URLSession.shared.data(for: peticion)
        guard (respuesta as? HTTPURLResponse)?.statusCode == 200 else {
            throw Fallo(detalle: "GitHub respondió \((respuesta as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return try interpretar(datos, actual: actual)
    }

    nonisolated static func descargar(_ version: Version,
                                      progreso: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if ConfigDeActualizacion.privado { return try bajarConGh(version) }
        let (bytes, respuesta) = try await URLSession.shared.bytes(from: version.dmg)
        guard (respuesta as? HTTPURLResponse)?.statusCode == 200 else { throw Fallo(detalle: "no se pudo descargar el DMG") }
        let total = max(1, respuesta.expectedContentLength)
        let destino = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(ConfigDeActualizacion.app)-\(version.numero)-\(UUID().uuidString).dmg")
        FileManager.default.createFile(atPath: destino.path, contents: nil)
        let manejador = try FileHandle(forWritingTo: destino)
        var trozo = Data(), recibidos: Int64 = 0
        for try await byte in bytes {
            trozo.append(byte)
            if trozo.count >= 1 << 20 {
                try manejador.write(contentsOf: trozo)
                recibidos += Int64(trozo.count)
                trozo.removeAll(keepingCapacity: true)
                progreso(min(1, Double(recibidos) / Double(total)))
            }
        }
        if !trozo.isEmpty { try manejador.write(contentsOf: trozo) }
        try manejador.close()
        progreso(1)
        try comprobarHash(destino, version)
        return destino
    }

    nonisolated static func rutaDeGh() throws -> String {
        guard let ruta = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first(where: FileManager.default.isExecutableFile) else {
            throw Fallo(detalle: "falta la herramienta gh (brew install gh) con tu sesión de GitHub")
        }
        return ruta
    }

    /// Repo privado: `gh release download` con la sesión guardada en el llavero.
    nonisolated static func bajarConGh(_ version: Version) throws -> URL {
        let carpeta = FileManager.default.temporaryDirectory.appendingPathComponent("act-gh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)
        let salida = try correr(try rutaDeGh(), ["release", "download", version.etiqueta,
                                                 "-R", ConfigDeActualizacion.repositorio, "-p", "*.dmg", "-D", carpeta.path])
        guard salida.codigo == 0, let dmg = try FileManager.default.contentsOfDirectory(
            at: carpeta, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "dmg" }) else {
            throw Fallo(detalle: "gh no pudo bajar el DMG: \(salida.texto)")
        }
        try comprobarHash(dmg, version)
        return dmg
    }

    nonisolated static func comprobarHash(_ destino: URL, _ version: Version) throws {
        if let esperado = version.sha256 {
            let datos = try Data(contentsOf: destino, options: .mappedIfSafe)
            let real = SHA256.hash(data: datos).map { String(format: "%02x", $0) }.joined()
            guard real == esperado else { throw Fallo(detalle: "la descarga no coincide con lo publicado en GitHub; no se instala") }
        }
    }

    @discardableResult
    nonisolated static func correr(_ orden: String, _ argumentos: [String]) throws -> (codigo: Int32, texto: String) {
        let proceso = Process()
        proceso.executableURL = URL(fileURLWithPath: orden)
        proceso.arguments = argumentos
        let tubo = Pipe()
        proceso.standardOutput = tubo
        proceso.standardError = tubo
        try proceso.run()
        let datos = tubo.fileHandleForReading.readDataToEndOfFile()
        proceso.waitUntilExit()
        return (proceso.terminationStatus, String(decoding: datos, as: UTF8.self))
    }

    /// La regla de firma («designated requirement»): incluye la huella del certificado.
    nonisolated static func reglaDeFirma(_ app: URL) -> String? {
        guard let salida = try? correr("/usr/bin/codesign", ["-d", "-r-", app.path]) else { return nil }
        return salida.texto.split(separator: "\n").first { $0.hasPrefix("designated =>") }.map(String.init)
    }

    nonisolated static func verificar(nueva: URL, contra instalada: URL) throws {
        guard try correr("/usr/bin/codesign", ["--verify", "--deep", "--strict", nueva.path]).codigo == 0 else {
            throw Fallo(detalle: "la firma de la app nueva no es válida")
        }
        guard let a = reglaDeFirma(nueva), let b = reglaDeFirma(instalada), a == b, !a.contains("cdhash") else {
            throw Fallo(detalle: "la app nueva no está firmada con el mismo certificado que la instalada")
        }
    }

    /// Abre el DMG, copia la app a una carpeta temporal y la comprueba.
    nonisolated static func preparar(dmg: URL, version: String, contra instalada: URL) throws -> URL {
        let gestor = FileManager.default
        let montaje = gestor.temporaryDirectory.appendingPathComponent("act-dmg-\(UUID().uuidString)")
        let carpeta = gestor.temporaryDirectory.appendingPathComponent("act-nueva-\(UUID().uuidString)")
        try gestor.createDirectory(at: montaje, withIntermediateDirectories: true)
        try gestor.createDirectory(at: carpeta, withIntermediateDirectories: true)
        guard try correr("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly",
                                              "-mountpoint", montaje.path, "-quiet"]).codigo == 0 else {
            throw Fallo(detalle: "no se pudo abrir el DMG")
        }
        defer { _ = try? correr("/usr/bin/hdiutil", ["detach", montaje.path, "-quiet"]) }
        let origen = montaje.appendingPathComponent("\(ConfigDeActualizacion.app).app")
        guard gestor.fileExists(atPath: origen.path) else { throw Fallo(detalle: "el DMG no trae \(ConfigDeActualizacion.app).app") }
        let nueva = carpeta.appendingPathComponent("\(ConfigDeActualizacion.app).app")
        guard try correr("/usr/bin/ditto", [origen.path, nueva.path]).codigo == 0 else {
            throw Fallo(detalle: "no se pudo copiar la app nueva")
        }
        try verificar(nueva: nueva, contra: instalada)
        let plist = NSDictionary(contentsOf: nueva.appendingPathComponent("Contents/Info.plist"))
        guard plist?["CFBundleShortVersionString"] as? String == version else {
            throw Fallo(detalle: "la app del DMG no es la versión \(version)")
        }
        return nueva
    }

    /// La vieja va a la Papelera (se puede recuperar); si la copia falla, vuelve a su sitio.
    nonisolated static func instalar(_ nueva: URL, en destino: URL) throws {
        let gestor = FileManager.default
        var enPapelera: NSURL?
        if gestor.fileExists(atPath: destino.path) { try gestor.trashItem(at: destino, resultingItemURL: &enPapelera) }
        let copia = try correr("/usr/bin/ditto", [nueva.path, destino.path])
        guard copia.codigo == 0 else {
            if let vieja = enPapelera as URL? { try? gestor.moveItem(at: vieja, to: destino) }
            throw Fallo(detalle: "no se pudo copiar a \(destino.path): \(copia.texto)")
        }
        _ = try? correr("/usr/bin/xattr", ["-dr", "com.apple.quarantine", destino.path])
    }

    /// Abre la versión nueva como otra instancia y cierra esta.
    static func relanzar(_ app: URL) {
        let configuracion = NSWorkspace.OpenConfiguration()
        configuracion.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: app, configuration: configuracion) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: - Ventana

    private func mostrar() {
        if ventana == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                                styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            panel.title = "Actualización de \(ConfigDeActualizacion.app)"
            panel.titlebarAppearsTransparent = true
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: VentanaDeActualizacion(modelo: self))
            panel.center()
            ventana = panel
        }
        NSApp.activate()
        ventana?.makeKeyAndOrderFront(nil)
    }
}

struct VentanaDeActualizacion: View {
    @ObservedObject var modelo: Actualizaciones

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 10) {
                contenido
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 30)
        .padding(.bottom, 18)
        .frame(width: 460, alignment: .topLeading)
    }

    @ViewBuilder private var contenido: some View {
        let app = ConfigDeActualizacion.app
        switch modelo.estado {
        case .disponible(let v):
            Text("\(app) \(v.numero) ya está disponible").font(.headline)
            Text("Tienes la \(Actualizaciones.versionActual). Se baja, se comprueba que sea tuya y se vuelve a abrir sola.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !v.notas.isEmpty {
                ScrollView {
                    Text((try? AttributedString(markdown: v.notas, options: .init(
                        interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(v.notas))
                        .font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        .padding(10)
                }
                .frame(height: 120)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
            }
            HStack {
                Toggle("Buscar al abrir", isOn: $modelo.buscarSola).toggleStyle(.checkbox).font(.callout)
                Spacer()
                Button("Ahora no") { modelo.omitir() }
                Button("Actualizar") { Task { await modelo.actualizar() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(modelo.ocupada())
                    .help(modelo.ocupada() ? "Espera a que termine lo que está haciendo" : "")
            }
            .padding(.top, 4)
        case .descargando(let v, let avance):
            Text("Bajando \(app) \(v.numero)…").font(.headline)
            ProgressView(value: avance)
            Text("\(Int(avance * 100)) %").font(.callout).foregroundStyle(.secondary)
        case .instalando(let v):
            Text("Instalando \(app) \(v.numero)…").font(.headline)
            Text("Comprobando la firma. Se abrirá sola en un momento.").font(.callout).foregroundStyle(.secondary)
            ProgressView().controlSize(.small)
        case .alDia:
            Text("Ya tienes la última versión").font(.headline)
            Text("\(app) \(Actualizaciones.versionActual) es la más reciente.").font(.callout).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Aceptar") { modelo.cerrar() }.keyboardShortcut(.defaultAction) }
        case .fallo(let motivo):
            Text("No se pudo actualizar").font(.headline)
            Text(motivo).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("Aceptar") { modelo.cerrar() }.keyboardShortcut(.defaultAction) }
        case .quieto, .buscando:
            Text("Buscando actualizaciones…").font(.headline)
            ProgressView().controlSize(.small)
        }
    }
}

/// «Buscar actualizaciones…» en el menú de la app, debajo de «Acerca de».
struct ComandosDeActualizacion: View {
    @ObservedObject var modelo = Actualizaciones.compartido

    var body: some View {
        Button("Buscar actualizaciones…") { Task { await modelo.buscar(aMano: true) } }
        Toggle("Buscar actualizaciones al abrir", isOn: $modelo.buscarSola)
    }
}
