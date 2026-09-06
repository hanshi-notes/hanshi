import AppKit
import SwiftUI

enum EditorFont {
    static let familyKey = "editorFontFamily"
    static let nameKey = "editorFontName"
    static let lineHeightKey = "editorLineHeight"
    static let ligaturesKey = "editorLigatures"
    static let sizeKey = "editorFontSize"
    static let defaultSize = 14.0
    static let sizeRange = 10.0...144.0

    static func clampedSize(_ size: Double) -> Double {
        size.isFinite ? min(max(size, sizeRange.lowerBound), sizeRange.upperBound) : defaultSize
    }

    static func clampedLineHeight(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 1), 3) : 1
    }

    static func resolve(name: String = "", family: String = "", size: Double) -> NSFont {
        let size = CGFloat(clampedSize(size))
        if !name.isEmpty, let font = NSFont(name: name, size: size) { return font }
        if !family.isEmpty,
           let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            return font
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            EditorSettingsView()
                .tabItem { Label("Appearance", systemImage: "eyeglasses") }
        }
    }
}

struct EditorSettingsView: View {
    @AppStorage(EditorFont.familyKey) private var family = ""
    @AppStorage(EditorFont.sizeKey) private var size = EditorFont.defaultSize
    @AppStorage(EditorFont.nameKey) private var name = ""
    @AppStorage(EditorFont.lineHeightKey) private var lineHeight = 1.0
    @AppStorage(EditorFont.ligaturesKey) private var ligatures = true

    private var boundedSize: Binding<Double> {
        Binding(get: { EditorFont.clampedSize(size) }, set: { size = EditorFont.clampedSize($0) })
    }

    private var selectedFont: Binding<NSFont> {
        Binding(get: { EditorFont.resolve(name: name, family: family, size: size) }, set: {
            name = $0.fontName
            family = $0.familyName ?? ""
            size = EditorFont.clampedSize($0.pointSize)
        })
    }

    var body: some View {
        Form {
            Section("Editor Font") {
                LabeledContent("Font") {
                    HStack(spacing: 6) {
                        HStack(spacing: 6) {
                            Text(selectedFont.wrappedValue.displayName ?? selectedFont.wrappedValue.fontName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity)
                            TextField("Font size", value: boundedSize, format: .number.grouping(.never))
                                .labelsHidden()
                                .textFieldStyle(.plain)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 40)
                        }
                        .padding(.horizontal, 6)
                        .frame(height: 22)
                        .background(Color(nsColor: .textBackgroundColor))
                        .overlay { Rectangle().strokeBorder(Color(nsColor: .separatorColor)) }
                        Stepper("Font size", value: boundedSize, in: EditorFont.sizeRange)
                            .labelsHidden()
                        FontPicker(font: selectedFont)
                            .fixedSize()
                    }
                }
                .accessibilityElement(children: .contain)
                HStack {
                    Toggle("Antialiasing", isOn: .constant(true))
                        .disabled(true)
                        .help("Managed by macOS. STTextView does not expose an antialiasing control.")
                    Toggle("Ligatures", isOn: $ligatures)
                }
                .toggleStyle(.checkbox)
                LabeledContent("Line height") {
                    HStack {
                        TextField("Line height", value: Binding(
                            get: { EditorFont.clampedLineHeight(lineHeight) },
                            set: { lineHeight = EditorFont.clampedLineHeight($0) }
                        ), format: .number.precision(.fractionLength(1)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                        Text("×").foregroundStyle(.secondary)
                        Stepper("Line height", value: $lineHeight, in: 1...3, step: 0.1)
                            .labelsHidden()
                    }
                }
            }
            Section("Preview") {
                EditorTypographyPreview(font: selectedFont.wrappedValue,
                                        lineHeight: EditorFont.clampedLineHeight(lineHeight), ligatures: ligatures)
                    .frame(height: 100)
            }
            Text("Changes apply immediately to all notes.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 440)
    }
}

private struct EditorTypographyPreview: NSViewRepresentable {
    let font: NSFont
    let lineHeight: Double
    let ligatures: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let text = scroll.documentView as! NSTextView
        text.isEditable = false
        text.drawsBackground = false
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let text = scroll.documentView as! NSTextView
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = lineHeight
        text.textStorage?.setAttributedString(NSAttributedString(
            string: "# Markdown\nOffice: fi fl ffi → != == =>\n0123456789 · {} [] ()",
            attributes: [.font: font, .foregroundColor: NSColor.labelColor,
                         .paragraphStyle: paragraph, .ligature: ligatures ? 1 : 0]
        ))
    }
}
