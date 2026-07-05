import SwiftUI
import AppKit

// MARK: - Estado global de la app

/// Controla si las calculadoras se mantienen por encima de las demás ventanas.
final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var alwaysOnTop = false {
        didSet { applyToAllWindows() }
    }

    // Nivel de ventana según el estado actual (.floating = sobre las demás apps).
    private var level: NSWindow.Level { alwaysOnTop ? .floating : .normal }

    // Aplica el nivel a todas las ventanas visibles.
    func applyToAllWindows() {
        for w in NSApp.windows where w.isVisible { w.level = level }
    }

    // Aplica el nivel a una ventana concreta (al abrirse una nueva).
    func apply(to window: NSWindow) { window.level = level }
}

/// Captura la NSWindow de la vista para aplicarle el nivel "siempre al frente".
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            if let w = v.window {
                AppState.shared.apply(to: w)
                w.makeKeyAndOrderFront(nil)
            }
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Lógica de la calculadora

final class CalculatorModel: ObservableObject {
    @Published var display: String = "0"      // número grande: operación en curso o resultado
    @Published var expression: String = ""    // línea gris: última operación completada
    @Published var activeOp: String? = nil     // operador resaltado

    private var entry: String = "0"            // operando en edición ("" = recién pulsado operador)
    private var stored: Double? = nil
    private var pending: String? = nil
    private var typing: Bool = false
    private var cleared: Bool = true           // estado "todo limpio" → muestra AC
    private var lastOp: String? = nil          // para repetir con "=" (5 + 3 = = → 11)
    private var lastOperand: Double? = nil
    private var isPercent: Bool = false        // entry termina en "%" pendiente de resolver

    // Etiqueta del botón superior izquierdo: AC cuando todo está limpio, C si hay entrada
    var clearLabel: String { cleared ? "AC" : "C" }

    // Punto de entrada único para botones y teclado
    func tap(_ key: String) {
        // Tras un "Error" solo tiene sentido limpiar o empezar un número nuevo;
        // operar sobre "Error" arrastraría estado inválido (NaN) o produciría "-Error".
        if display == "Error" {
            switch key {
            case "0"..."9", ",":
                resetAll()
            case "AC", "C":
                break
            default:
                return
            }
        }
        switch key {
        case "0","1","2","3","4","5","6","7","8","9": inputDigit(key)
        case ",":  inputDecimal()
        case "AC", "C": tapClear()
        case "±":  negate()
        case "%":  percent()
        case "+","−","×","÷": setOperation(key)
        case "=":  equals()
        default: break
        }
        refreshDisplay()
    }

    // El display grande muestra la operación completa mientras se construye
    // ("200 + 10%"); al dar "=" queda el resultado y la línea gris guarda la expresión.
    private func refreshDisplay() {
        if let s = stored, let op = pending {
            display = format(s) + " " + op + (entry.isEmpty ? "" : " " + entry)
        } else {
            display = entry
        }
    }

    private func resetAll() {
        entry = "0"; expression = ""; stored = nil; pending = nil
        typing = false; cleared = true; isPercent = false
        lastOp = nil; lastOperand = nil; activeOp = nil
    }

    private func inputDigit(_ d: String) {
        isPercent = false
        cleared = false
        if !typing {
            entry = d
            typing = true
        } else if entry == "0" {
            entry = d
        } else {
            entry += d
        }
        activeOp = nil
    }

    private func inputDecimal() {
        isPercent = false
        cleared = false
        if !typing {
            entry = "0,"
            typing = true
        } else if !entry.contains(",") {
            entry += ","
        }
        activeOp = nil
    }

    private func tapClear() {
        if cleared {
            // AC: reinicio total
            resetAll()
        } else {
            // C: limpia solo la entrada actual
            entry = "0"; typing = false; cleared = true; isPercent = false
        }
        activeOp = nil
    }

    private func negate() {
        // Tras un operador ("200 + ±") el operando parte del número almacenado
        if entry.isEmpty {
            guard let s = stored else { return }
            entry = rawString(s)
        }
        if entry.hasPrefix("-") { entry.removeFirst() }
        else if entry != "0" { entry = "-" + entry }
    }

    private func percent() {
        // "%" diferido: se muestra "10%" tal cual; el valor real se resuelve
        // en operandValue() al dar "=" o encadenar otro operador.
        guard !isPercent else { return }
        if entry.isEmpty { entry = rawString(stored ?? 0) }   // "200 + %" → "200 + 200%"
        if entry.hasSuffix(",") { entry.removeLast() }
        entry += "%"
        isPercent = true
        typing = false
    }

    // Valor efectivo del operando en edición. Si es "N%": con suma/resta pendiente
    // es porcentaje del número anterior (200 + 10% → 20); con ×/÷ o suelto, N/100.
    private func operandValue() -> Double {
        let v = currentValue()
        guard isPercent else { return v }
        if let s = stored, let op = pending, op == "+" || op == "−" {
            return s * v / 100
        }
        return v / 100
    }

    private func setOperation(_ op: String) {
        if pending != nil && (typing || isPercent) {
            // encadenar: 200 + 10 × → calcula 210 y sigue con "210 ×"
            let result = compute(stored ?? 0, operandValue(), pending!)
            if result.isNaN || result.isInfinite {
                resetAll()
                entry = "Error"
                cleared = false
                return
            }
            stored = result
        } else if pending == nil {
            stored = operandValue()   // resuelve también "50% +" → "0,5 +"
        }
        // (con pending y sin operando tecleado: solo cambia el operador)
        entry = ""
        isPercent = false
        pending = op
        typing = false
        cleared = false
        activeOp = op
        expression = ""   // la operación en curso ahora vive en el display grande
    }

    private func equals() {
        guard let op = pending, let s = stored else {
            if isPercent {
                // "50% =" suelto: resolver el porcentaje a su valor
                let value = operandValue()
                expression = entry + " ="
                entry = format(value)
                isPercent = false
                typing = false
                cleared = false
                return
            }
            // "=" repetido: repite la última operación sobre el resultado (5 + 3 = = → 11)
            guard let op = lastOp, let operand = lastOperand else { return }
            let value = currentValue()
            let result = compute(value, operand, op)
            expression = format(value) + " " + op + " " + format(operand) + " ="
            entry = format(result)
            typing = false
            cleared = false
            return
        }
        let value: Double
        let shown: String
        if entry.isEmpty {
            // "200 + =": usa el número almacenado como segundo operando (como Apple)
            value = s
            shown = format(s)
        } else {
            value = operandValue()
            shown = isPercent ? entry : format(value)   // "200 + 10% =" en la línea gris
        }
        let result = compute(s, value, op)
        expression = format(s) + " " + op + " " + shown + " ="
        entry = format(result)
        isPercent = false
        lastOp = op
        lastOperand = value
        pending = nil
        stored = nil
        typing = false
        cleared = false
        activeOp = nil
    }

    func backspace() {
        defer { refreshDisplay() }
        // Sobre "N%" el primer borrado quita solo el "%" y vuelve a modo edición
        if entry.hasSuffix("%") {
            entry = String(entry.dropLast()).replacingOccurrences(of: ".", with: "")
            isPercent = false
            typing = true
            return
        }
        // Con "200 +" (sin operando aún), borrar quita el operador y vuelve a editar el 200
        if entry.isEmpty {
            guard let s = stored, pending != nil else { entry = "0"; return }
            entry = rawString(s)
            stored = nil
            pending = nil
            activeOp = nil
            typing = true
            return
        }
        // Si no estábamos tecleando (resultado, recién abierta, etc.) pasamos a modo
        // edición sobre el número que se ve, quitando el separador de miles "."
        if !typing {
            if entry == "0" || entry == "Error" { return }
            entry = entry.replacingOccurrences(of: ".", with: "")
            typing = true
        }
        let isNeg = entry.hasPrefix("-")
        if entry.count <= 1 || (entry.count == 2 && isNeg) {
            entry = "0"; typing = false
        } else {
            entry.removeLast()
            if entry == "-" { entry = "0"; typing = false }
        }
    }

    // Copia el número mostrado al portapapeles (para pegarlo en Notas, etc.)
    func copyToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(display, forType: .string)
    }

    // MARK: helpers numéricos (coma colombiana)

    private func compute(_ a: Double, _ b: Double, _ op: String) -> Double {
        switch op {
        case "+": return a + b
        case "−": return a - b
        case "×": return a * b
        case "÷": return b == 0 ? Double.nan : a / b
        default:  return b
        }
    }

    private func currentValue() -> Double {
        // "." = separador de miles, "," = decimal → normalizar a formato Double
        let cleanedStr = entry
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: ".")
        return Double(cleanedStr) ?? 0
    }

    // Versión editable de un número ya calculado (sin separador de miles)
    private func rawString(_ v: Double) -> String {
        format(v).replacingOccurrences(of: ".", with: "")
    }

    private func format(_ v: Double) -> String {
        if v.isNaN || v.isInfinite { return "Error" }
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.locale = Locale(identifier: "es_CO")
        nf.maximumFractionDigits = 8
        nf.minimumFractionDigits = 0
        return nf.string(from: NSNumber(value: v)) ?? "0"
    }
}

// MARK: - Vista

struct CalculatorView: View {
    @StateObject private var model = CalculatorModel()
    @ObservedObject private var appState = AppState.shared
    @FocusState private var focused: Bool
    @Environment(\.openWindow) private var openWindow

    private let spacing: CGFloat = 12
    private let size: CGFloat = 64

    // Paleta estilo Calculadora de macOS
    private let grayBtn  = Color(red: 0.65, green: 0.65, blue: 0.65)
    private let darkBtn  = Color(red: 0.20, green: 0.20, blue: 0.20)
    private let orange   = Color(red: 1.0,  green: 0.62, blue: 0.04)

    var body: some View {
        VStack(spacing: spacing) {
            displayArea
            buttonsGrid
        }
        .padding(spacing)
        .background(Color.black)
        .background(WindowConfigurator())
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            focused = true
            WindowOpener.openNew = { openWindow(id: "calc") }
        }
        .onKeyPress(.delete) { model.backspace(); return .handled }
        .onKeyPress(.deleteForward) { model.backspace(); return .handled }
        .onKeyPress { handleKey($0) }
    }

    // Ancho de la grilla: 4 columnas + 3 espacios
    private var gridWidth: CGFloat { size * 4 + spacing * 3 }

    private var displayArea: some View {
        HStack(alignment: .bottom, spacing: 4) {
            // Botón borrar último dígito (⌫)
            Button { model.backspace() } label: {
                Image(systemName: "delete.left")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundColor(.gray)
            }
            .buttonStyle(.plain)
            .help("Borrar último dígito (también: tecla ⌫ o desliza sobre el número)")

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 2) {
                Text(model.expression.isEmpty ? " " : model.expression)
                    .font(.system(size: 15))
                    .foregroundColor(.gray)
                    .lineLimit(1)
                Text(model.display)
                    .font(.system(size: 46, weight: .light))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.35)
            }
            // Deslizar a la izquierda sobre el número también borra
            .gesture(
                DragGesture(minimumDistance: 18)
                    .onEnded { if $0.translation.width < -18 { model.backspace() } }
            )
        }
        .frame(width: gridWidth, height: 86, alignment: .bottom)
        .padding(.horizontal, 6)
        // Clic derecho sobre el área del número → Copiar / opciones de ventana
        .contextMenu {
            Button("Copiar") { model.copyToClipboard() }
            Divider()
            Button("Nueva ventana") { openWindow(id: "calc") }
            Toggle("Mantener al frente", isOn: $appState.alwaysOnTop)
        }
    }

    private var buttonsGrid: some View {
        VStack(spacing: spacing) {
            HStack(spacing: spacing) {
                funcButton(model.clearLabel)
                funcButton("±")
                funcButton("%")
                opButton("÷")
            }
            HStack(spacing: spacing) {
                digitButton("7"); digitButton("8"); digitButton("9"); opButton("×")
            }
            HStack(spacing: spacing) {
                digitButton("4"); digitButton("5"); digitButton("6"); opButton("−")
            }
            HStack(spacing: spacing) {
                digitButton("1"); digitButton("2"); digitButton("3"); opButton("+")
            }
            HStack(spacing: spacing) {
                wideZero()
                digitButton(",")
                opButton("=")
            }
        }
    }

    // Botones gris claro: AC/C, ±, %
    private func funcButton(_ label: String) -> some View {
        Button { model.tap(label) } label: {
            Group {
                if label == "±" {
                    // Símbolo igual al de la Calculadora de macOS (+/− diagonal)
                    Image(systemName: "plus.forwardslash.minus")
                        .font(.system(size: 22, weight: .medium))
                } else {
                    Text(label)
                        .font(.system(size: 24, weight: .medium))
                }
            }
            .foregroundColor(.black)
            .frame(width: size, height: size)
            .background(grayBtn)
            .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // Botones dígito / coma
    private func digitButton(_ label: String) -> some View {
        Button { model.tap(label) } label: {
            Text(label)
                .font(.system(size: 26, weight: .regular))
                .foregroundColor(.white)
                .frame(width: size, height: size)
                .background(darkBtn)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // "0" ancho (capsula que ocupa 2 columnas)
    private func wideZero() -> some View {
        Button { model.tap("0") } label: {
            Text("0")
                .font(.system(size: 26))
                .foregroundColor(.white)
                .frame(width: size * 2 + spacing, height: size, alignment: .center)
                .background(darkBtn)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // Símbolo de sistema para cada operador (centrado óptico perfecto, como la Calculadora de macOS)
    private func opSymbol(_ op: String) -> String {
        switch op {
        case "÷": return "divide"
        case "×": return "multiply"
        case "−": return "minus"
        case "+": return "plus"
        case "=": return "equal"
        default:  return "questionmark"
        }
    }

    // Operadores naranjas, con resaltado del activo
    private func opButton(_ op: String) -> some View {
        let active = model.activeOp == op
        return Button { model.tap(op) } label: {
            Image(systemName: opSymbol(op))
                .font(.system(size: 26, weight: .medium))
                .foregroundColor(active ? orange : .white)
                .frame(width: size, height: size)
                .background(active ? Color.white : orange)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: teclado físico
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        // Cmd+C → copiar el número mostrado al portapapeles
        if press.modifiers.contains(.command) {
            if press.characters.lowercased() == "c" {
                model.copyToClipboard()
                return .handled
            }
            return .ignored   // dejar pasar otros atajos del sistema (Cmd+N, etc.)
        }
        switch press.key {
        case .return:  model.tap("="); return .handled
        case .delete:  model.backspace(); return .handled
        case .escape:  model.tap("AC"); return .handled
        default: break
        }
        guard let c = press.characters.first else { return .ignored }
        switch c {
        case "0"..."9": model.tap(String(c)); return .handled
        case "+": model.tap("+"); return .handled
        case "-": model.tap("−"); return .handled
        case "*": model.tap("×"); return .handled
        case "/": model.tap("÷"); return .handled
        case "=": model.tap("="); return .handled
        case ",", ".": model.tap(","); return .handled
        case "%": model.tap("%"); return .handled
        case "c", "C": model.tap("AC"); return .handled
        case "\u{7F}", "\u{08}": model.backspace(); return .handled   // DEL / BS de respaldo
        default: return .ignored
        }
    }
}

// MARK: - App

// Puente para que el delegate pueda abrir ventanas nuevas (lo setea la vista al aparecer)
enum WindowOpener { static var openNew: (() -> Void)? }

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Clic en el icono del Dock → solo trae al frente la ventana existente
    // (si no hay ninguna, SwiftUI restaura una). Para abrir OTRA calculadora:
    // clic derecho en el Dock → "Nueva ventana", o Cmd+N.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        return true
    }

    // Menú de clic derecho sobre el icono del Dock.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()

        let nueva = NSMenuItem(title: "Nueva ventana", action: #selector(newWindow), keyEquivalent: "")
        nueva.target = self
        menu.addItem(nueva)

        menu.addItem(.separator())

        let alFrente = NSMenuItem(title: "Mantener al frente", action: #selector(toggleAlwaysOnTop), keyEquivalent: "")
        alFrente.target = self
        alFrente.state = AppState.shared.alwaysOnTop ? .on : .off
        menu.addItem(alFrente)

        return menu
    }

    // Elegir un ítem del menú del Dock NO activa la app por sí solo → la ventana
    // nueva nacía detrás de la app en primer plano. Activar antes de abrir.
    @objc private func newWindow() {
        NSApp.activate()
        WindowOpener.openNew?()
    }
    @objc private func toggleAlwaysOnTop() { AppState.shared.alwaysOnTop.toggle() }
}

@main
struct CalculadoraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: "calc") {
            CalculatorView()
        }
        .windowResizability(.contentSize)
    }
}
