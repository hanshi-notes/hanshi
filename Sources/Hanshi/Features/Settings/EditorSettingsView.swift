import AppKit
import SwiftUI

enum EditorFont {
    static let familyKey = "editorFontFamily"
    static let nameKey = "editorFontName"
    static let lineHeightKey = "editorLineHeight"
    static let ligaturesKey = "editorLigatures"
    static let sizeKey = "editorFontSize"
    static let gutterKey = "editorShowsGutter"
    static let tabWidthKey = "editorTabWidth"
    static let indentsWithTabsKey = "editorIndentsWithTabs"
    static let letterSpacingKey = "editorLetterSpacing"
    static let invisiblesKey = "editorShowsInvisibles"
    static let letterSpacingRange = 0.8...2.0
    static let defaultTabWidth = 4
    static let tabWidthRange = 1...8
    static let defaultSize = 14.0
    static let sizeRange = 10.0...144.0

    static func clampedSize(_ size: Double) -> Double {
        size[clampedTo: sizeRange, fallback: defaultSize]
    }

    static var showsGutter: Bool { UserDefaults.standard.object(forKey: gutterKey) as? Bool ?? true }
    static var tabWidth: Int { clampedTabWidth(UserDefaults.standard.object(forKey: tabWidthKey) as? Int ?? defaultTabWidth) }
    static var indentsWithTabs: Bool { UserDefaults.standard.bool(forKey: indentsWithTabsKey) }

    static var showsInvisibles: Bool { UserDefaults.standard.bool(forKey: invisiblesKey) }

    static func clampedLetterSpacing(_ value: Double) -> Double {
        value[clampedTo: letterSpacingRange, fallback: 1]
    }

    static func clampedTabWidth(_ width: Int) -> Int {
        width[clampedTo: tabWidthRange]
    }

    static func clampedLineHeight(_ value: Double) -> Double {
        value[clampedTo: 1...3, fallback: 1]
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
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            EditorSettingsView()
                .tabItem { Label("Appearance", systemImage: "eyeglasses") }
            TextEditingSettingsView()
                .tabItem { Label("Editing", systemImage: "text.alignleft") }
            NoteSettingsView()
                .tabItem { Label("Notes", systemImage: "doc.text") }
        }
    }
}

struct GeneralSettingsView: View {
    @AppStorage(ContentMode.startupKey) private var startupMode = ContentMode.source
    @AppStorage(Note.hidesExtensionKey) private var hidesExtension = true
    @AppStorage(Autosave.enabledKey) private var autosaveEnabled = true
    @AppStorage(Autosave.secondsKey) private var autosaveSeconds = Autosave.defaultSeconds

    private var boundedSeconds: Binding<Int> {
        $autosaveSeconds[clampedTo: Autosave.secondsRange]
    }

    var body: some View {
        Form {
            Section("Saving") {
                Toggle("Save notes automatically", isOn: $autosaveEnabled)
                    .toggleStyle(.switch)
                    .accessibilityIdentifier(Autosave.enabledKey)
                LabeledContent("Save every") {
                    HStack {
                        TextField("Save every", value: boundedSeconds, format: .number.grouping(.never))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 44)
                        Text("seconds").foregroundStyle(.secondary)
                        Stepper("Save every", value: boundedSeconds, in: Autosave.secondsRange, step: 5)
                            .labelsHidden()
                    }
                }
                .accessibilityIdentifier(Autosave.secondsKey)
                .disabled(!autosaveEnabled)
                Text(autosaveEnabled
                     ? "A note you are writing is saved this often, so a crash costs at most that much typing."
                     : "Notes are only saved with ⌘S, or when you close a note with unsaved changes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Startup") {
                Picker("View when opening the app", selection: $startupMode) {
                    ForEach(ContentMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .help("Applies the next time the app opens.")
            }
            Section("Note List") {
                Toggle("Hide file extensions", isOn: $hidesExtension)
                    .toggleStyle(.checkbox)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 440)
    }
}

struct TextEditingSettingsView: View {
    @AppStorage(PreviewSettings.autoClosePairsKey) private var autoClosePairs = true
    @AppStorage(PreviewSettings.allowsEditingKey) private var allowsPreviewEditing = true
    @AppStorage(PreviewSettings.showsMarkdownMarkersKey) private var showsPreviewMarkers = false
    @AppStorage(EditorFont.gutterKey) private var showsGutter = true
    @AppStorage(EditorFont.indentsWithTabsKey) private var indentsWithTabs = false
    @AppStorage(EditorFont.tabWidthKey) private var tabWidth = EditorFont.defaultTabWidth
    @AppStorage(EditorFont.invisiblesKey) private var showsInvisibles = false
    @AppStorage(PreviewSettings.bodySizeKey) private var previewBodySize = PreviewTheme.defaultBodySize
    @AppStorage(PreviewSettings.marginKey) private var previewMargin = PreviewTheme.defaultMargin
    @AppStorage(PreviewSettings.verticalMarginKey) private var previewVerticalMargin = PreviewTheme.defaultVerticalMargin
    @AppStorage(PreviewSettings.fontNameKey) private var previewFontName = ""
    @AppStorage(PreviewSettings.fontFamilyKey) private var previewFontFamily = ""
    @AppStorage(PreviewSettings.lineHeightKey) private var previewLineHeight = PreviewTheme.defaultLineHeight

    private var boundedTabWidth: Binding<Int> {
        $tabWidth[clampedTo: EditorFont.tabWidthRange]
    }

    private var boundedPreviewBodySize: Binding<Double> {
        $previewBodySize[clampedTo: PreviewTheme.bodySizeRange, fallback: PreviewTheme.defaultBodySize]
    }

    private var boundedPreviewMargin: Binding<Double> {
        $previewMargin[clampedTo: PreviewTheme.marginRange, fallback: PreviewTheme.defaultMargin]
    }

    private var boundedPreviewVerticalMargin: Binding<Double> {
        $previewVerticalMargin[clampedTo: PreviewTheme.verticalMarginRange, fallback: PreviewTheme.defaultVerticalMargin]
    }

    private var boundedPreviewLineHeight: Binding<Double> {
        $previewLineHeight[clampedTo: PreviewTheme.lineHeightRange, fallback: PreviewTheme.defaultLineHeight]
    }

    private var previewTheme: PreviewTheme {
        PreviewTheme(bodySize: previewBodySize, fontName: previewFontName, fontFamily: previewFontFamily)
    }

    /// The font panel hands back a face and a size together, so both settings move with it.
    private var previewFont: Binding<NSFont> {
        Binding(get: { previewTheme.bodyFont(size: PreviewTheme.clampedBodySize(previewBodySize)) },
                set: {
                    previewFontName = $0.fontName
                    previewFontFamily = $0.familyName ?? ""
                    previewBodySize = PreviewTheme.clampedBodySize($0.pointSize)
                })
    }

    var body: some View {
        Form {
            Section("Text Editing") {
                Picker("Prefer indent using", selection: $indentsWithTabs) {
                    Text("Spaces").tag(false)
                    Text("Tabs").tag(true)
                }
                LabeledContent("Tab width") {
                    HStack {
                        TextField("Tab width", value: boundedTabWidth, format: .number.grouping(.never))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 40)
                        Stepper("Tab width", value: boundedTabWidth, in: EditorFont.tabWidthRange)
                            .labelsHidden()
                        Text("spaces").foregroundStyle(.secondary)
                    }
                }
                Toggle("Show line numbers", isOn: $showsGutter)
                    .toggleStyle(.switch)
                Toggle("Automatically close brackets", isOn: $autoClosePairs)
                    .toggleStyle(.switch)
                    .accessibilityIdentifier(PreviewSettings.autoClosePairsKey)
                    .help("Automatically closes (), [] and {} while editing preview.")
                Toggle("Show invisible characters", isOn: $showsInvisibles)
                    .toggleStyle(.switch)
                    .help("Shows tabs, spaces and line breaks.")
            }
            Text("A tab is as wide as this many spaces, whichever key inserts it.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Section("Markdown Preview") {
                Toggle("Allow editing in preview", isOn: $allowsPreviewEditing)
                    .toggleStyle(.switch)
                    .accessibilityIdentifier(PreviewSettings.allowsEditingKey)
                Toggle("Show Markdown markers while editing preview", isOn: $showsPreviewMarkers)
                    .toggleStyle(.switch)
                    .accessibilityIdentifier(PreviewSettings.showsMarkdownMarkersKey)
                    .disabled(!allowsPreviewEditing)
                    .help("Reveals markers such as *, ** and ~~ around the text you are editing.")
                LabeledContent("Font") {
                    HStack(spacing: 6) {
                        Text(previewFont.wrappedValue.displayName ?? previewFont.wrappedValue.fontName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !previewFontName.isEmpty || !previewFontFamily.isEmpty {
                            Button("System") { previewFontName = ""; previewFontFamily = "" }
                                .help("Go back to the system reading font.")
                        }
                        FontPicker(font: previewFont, label: "Select preview font")
                            .fixedSize()
                    }
                }
                .accessibilityIdentifier(PreviewSettings.fontNameKey)
                LabeledContent("Line height") {
                    HStack {
                        TextField("Line height", value: boundedPreviewLineHeight,
                                  format: .number.precision(.fractionLength(2)))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 44)
                        Text("×").foregroundStyle(.secondary)
                        Stepper("Line height", value: boundedPreviewLineHeight,
                                in: PreviewTheme.lineHeightRange, step: 0.05)
                            .labelsHidden()
                    }
                }
                .accessibilityIdentifier(PreviewSettings.lineHeightKey)
                LabeledContent("Text size") {
                    HStack {
                        TextField("Text size", value: boundedPreviewBodySize, format: .number.grouping(.never))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 44)
                        Text("pt").foregroundStyle(.secondary)
                        Stepper("Text size", value: boundedPreviewBodySize, in: PreviewTheme.bodySizeRange)
                            .labelsHidden()
                    }
                }
                .accessibilityIdentifier(PreviewSettings.bodySizeKey)
                LabeledContent("Side margin") {
                    HStack {
                        TextField("Side margin", value: boundedPreviewMargin, format: .number.grouping(.never))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 44)
                        Text("pt").foregroundStyle(.secondary)
                        Stepper("Side margin", value: boundedPreviewMargin, in: PreviewTheme.marginRange, step: 2)
                            .labelsHidden()
                    }
                }
                .accessibilityIdentifier(PreviewSettings.marginKey)
                LabeledContent("Top and bottom margin") {
                    HStack {
                        TextField("Top and bottom margin", value: boundedPreviewVerticalMargin,
                                  format: .number.grouping(.never))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 44)
                        Text("pt").foregroundStyle(.secondary)
                        Stepper("Top and bottom margin", value: boundedPreviewVerticalMargin,
                                in: PreviewTheme.verticalMarginRange, step: 2)
                            .labelsHidden()
                    }
                }
                .accessibilityIdentifier(PreviewSettings.verticalMarginKey)
                Text("Code follows the text size, so the preview keeps its proportions.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 440)
    }
}

struct NoteSettingsView: View {
    @AppStorage(NoteTitle.templateKey) private var usesTitleTemplate = true

    var body: some View {
        Form {
            Section("New Notes") {
                Toggle("Start with a \"# Note\" heading", isOn: $usesTitleTemplate)
                    .toggleStyle(.checkbox)
                Text(usesTitleTemplate
                     ? "The file is renamed to follow the heading, until you rename the note yourself."
                     : "New notes open empty and keep the name they were created with.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 440)
    }
}

struct EditorSettingsView: View {
    @AppStorage(SidebarTheme.key) private var sidebarTheme = SidebarTheme.standard
    @AppStorage(EditorFont.familyKey) private var family = ""
    @AppStorage(EditorFont.sizeKey) private var size = EditorFont.defaultSize
    @AppStorage(EditorFont.nameKey) private var name = ""
    @AppStorage(EditorFont.lineHeightKey) private var lineHeight = 1.0
    @AppStorage(EditorFont.ligaturesKey) private var ligatures = true
    @AppStorage(EditorFont.letterSpacingKey) private var letterSpacing = 1.0
    @AppStorage(SyntaxTheme.key) private var theme = SyntaxTheme.system.rawValue

    private var boundedSize: Binding<Double> {
        $size[clampedTo: EditorFont.sizeRange, fallback: EditorFont.defaultSize]
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
            Section("Sidebar") {
                Picker("Color", selection: $sidebarTheme) {
                    ForEach(SidebarTheme.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Sidebar color")
            }
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
                        .help("Managed by macOS.")
                    Toggle("Ligatures", isOn: $ligatures)
                }
                .toggleStyle(.checkbox)
                LabeledContent("Line height") {
                    HStack {
                        TextField("Line height", value: $lineHeight[clampedTo: 1...3, fallback: 1], format: .number.precision(.fractionLength(1)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                        Text("×").foregroundStyle(.secondary)
                        Stepper("Line height", value: $lineHeight, in: 1...3, step: 0.1)
                            .labelsHidden()
                    }
                }
                LabeledContent("Letter spacing") {
                    HStack {
                        TextField("Letter spacing", value: $letterSpacing[clampedTo: EditorFont.letterSpacingRange, fallback: 1], format: .number.precision(.fractionLength(2)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                        Text("×").foregroundStyle(.secondary)
                        Stepper("Letter spacing", value: $letterSpacing, in: EditorFont.letterSpacingRange, step: 0.05)
                            .labelsHidden()
                    }
                }
            }
            Section("Syntax Colors") {
                ForEach(SyntaxTheme.allCases) { option in
                    Button { theme = option.rawValue } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark")
                                .opacity(theme == option.rawValue ? 1 : 0)
                            Text(option.name)
                            Spacer(minLength: 8)
                            SyntaxSwatch(colors: option.swatch, background: option.background)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(theme == option.rawValue ? [.isButton, .isSelected] : .isButton)
                }
            }
            Section("Preview") {
                EditorTypographyPreview(font: selectedFont.wrappedValue,
                                        lineHeight: EditorFont.clampedLineHeight(lineHeight), ligatures: ligatures,
                                        theme: SyntaxTheme(rawValue: theme) ?? .system)
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

private struct SyntaxSwatch: View {
    let colors: [NSColor]
    let background: NSColor?

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                Circle().fill(Color(nsColor: color)).frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color(nsColor: background ?? .textBackgroundColor)))
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
        .accessibilityHidden(true)
    }
}

private struct EditorTypographyPreview: NSViewRepresentable {
    let font: NSFont
    let lineHeight: Double
    let ligatures: Bool
    let theme: SyntaxTheme

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let text = scroll.documentView as! NSTextView
        text.isEditable = false
        text.drawsBackground = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let text = scroll.documentView as! NSTextView
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = lineHeight
        text.appearance = theme.appearance
        text.backgroundColor = theme.background ?? .textBackgroundColor
        text.textStorage?.setAttributedString(NSAttributedString(
            string: "# Markdown\nOffice: fi fl ffi → != == =>\n0123456789 · {} [] ()",
            attributes: [.font: font, .foregroundColor: theme.plain,
                         .paragraphStyle: paragraph, .ligature: ligatures ? 1 : 0]
        ))
        text.layoutManager?.addTemporaryAttribute(.foregroundColor, value: theme.colors["H1"] ?? theme.plain,
                                                  forCharacterRange: NSRange(location: 0, length: 10))
    }
}
