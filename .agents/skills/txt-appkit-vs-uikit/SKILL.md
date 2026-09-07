---
name: txt-appkit-vs-uikit
description: Compare NSTextView and UITextView capabilities for porting between macOS and iOS, building Mac Catalyst editors, or planning cross-platform text features. Covers the AppKit-only stack (text tables, rulers, font/list/table/spacing panels, grammar checking, text completion, Services menu, field editor, NSText RTF I/O) and the UIKit-only stack (UITextInteraction, UITextItem interactions, UITextSelectionDisplayInteraction, UITextLoupeSession, declarative dataDetectorTypes), plus the architectural differences (scroll view, inheritance, delegate richness, Writing Tools coordinator, fallback detection). Use when porting a text editor between platforms, when a feature is missing on one side, or when scoping cross-platform work. Do NOT use for picking among SwiftUI views — see txt-view-picker.
license: MIT
---

# AppKit vs UIKit Text Capabilities

Authored against iOS 26.x / macOS 26.x / Swift 6.x / Xcode 26.x.

This skill is a capability comparison between `NSTextView` and `UITextView`. The differences below are real, but the framework boundaries shift over releases — TextKit 2 is now the default on both, Writing Tools shipped on both, find/replace shipped on both. Before declaring a feature "AppKit-only" or "UIKit-only" for production code, verify against the current SDK rather than this skill alone; check Sosumi for the latest API set on both sides.

A capability gap is one of three things. **Architectural** — the platform genuinely lacks the concept (Services menu has no iOS analogue; UITextInteraction has no AppKit analogue). **API-level** — the feature exists on both sides but the entry point differs (find/replace via `UIFindInteraction` vs `NSTextFinder`). **Stack-level** — both views have the feature but only with the right TextKit version (Writing Tools requires TextKit 2 on both). Naming the kind of gap is what determines whether porting is a wrapper job, an API translation, or a real reimplementation.

## Contents

- [AppKit-only capabilities](#appkit-only-capabilities)
- [UIKit-only capabilities](#uikit-only-capabilities)
- [Architectural differences](#architectural-differences)
- [Writing Tools across the platforms](#writing-tools-across-the-platforms)
- [Fallback detection](#fallback-detection)
- [Cross-platform feature parity](#cross-platform-feature-parity)
- [Common mistakes when porting](#common-mistakes-when-porting)
- [References](#references)

## AppKit-only capabilities

Several `NSTextView` features have no `UITextView` counterpart and likely never will, because they describe macOS-specific concepts.

**Built-in formatting panels.** `usesFontPanel`, `usesRuler` / `isRulerVisible`, `orderFrontLinkPanel:`, `orderFrontListPanel:`, `orderFrontTablePanel:`, `orderFrontSpacingPanel:`, `orderFrontSubstitutionsPanel:`. These wire `NSTextView` into the system Font, Ruler, and substitutions panels. iOS has no system panels for these — UIKit apps build the equivalent UI themselves.

**Text tables.** `NSTextTable` and `NSTextTableBlock` provide row/column-spanning tabular layout inside a single text view, with per-cell borders, backgrounds, and padding. The full path goes through paragraph styles:

```swift
let table = NSTextTable()
table.numberOfColumns = 3

let cell = NSTextTableBlock(table: table, startingRow: 0,
                            rowSpan: 1, startingColumn: 0, columnSpan: 1)
cell.backgroundColor = .lightGray
cell.setWidth(1.0, type: .absoluteValueType, for: .border)

let style = NSMutableParagraphStyle()
style.textBlocks = [cell]
```

UIKit has no equivalent. Note that `NSTextTable` is a TextKit 1 feature and using it triggers TextKit 1 fallback on `NSTextView`.

**Grammar checking and text completion.** `isGrammarCheckingEnabled`, `toggleGrammarChecking(_:)`, `complete(_:)`, `isAutomaticTextCompletionEnabled`, plus the `completions(forPartialWordRange:indexOfSelectedItem:)` override. UIKit has no grammar API and no built-in completion infrastructure — text completion has to be built on top of `UITextInput` with custom overlay views.

**Spell-checking granular control.** `setSpellingState(_:range:)` to mark specific ranges as misspelled, `spellCheckerDocumentTag()` for document-tag management, `isContinuousSpellCheckingEnabled` toggle. UIKit exposes only `spellCheckingType: .yes/.no/.default` — no per-range marking, no document tag.

**Smart substitutions as individual toggles.** AppKit has separate properties for smart quotes, smart dashes, text replacement, auto-spelling correction, link detection, and data detection (`isAutomaticQuoteSubstitutionEnabled`, etc.) plus a Substitutions Panel for user configuration. UIKit collapses these into a few `UITextInputTraits` enum properties (`smartQuotesType`, `smartDashesType`, `autocorrectionType`).

**Services menu integration.** `NSTextView` automatically conforms to `NSServicesMenuRequestor`, so its selected text appears in macOS Services menu items ("Look Up in Dictionary," third-party services, etc.). For custom views, override `validRequestor(forSendType:returnType:)`. iOS has no Services concept.

**Field editor.** A single shared `NSTextView` per window edits all `NSTextField` instances. Memory-efficient and consistent, but with sharp edges — touching `layoutManager` on one field's editor flips all fields in the window to TextKit 1. UIKit has no field editor; each `UITextField` manages its own editing state.

**NSText heritage.** `NSTextView` inherits from `NSText`, which gives it direct RTF/RTFD I/O (`rtf(from:)`, `rtfd(from:)`, `replaceCharacters(in:withRTF:)`, `writeRTFD(toFile:atomically:)`), font/ruler pasteboards (`copyFont(_:)`, `pasteFont(_:)`, `copyRuler(_:)`, `pasteRuler(_:)`), and speech (`startSpeaking(_:)`, `stopSpeaking(_:)`). UIKit has none of these — RTF requires manual `NSAttributedString` initialization with format options, and speech goes through `AVSpeechSynthesizer`.

**Print support.** `printView(_:)` via the NSView print system. A subtle Dark Mode pitfall: `printView(nil)` renders with current appearance, so a Dark Mode app prints white text on white paper. Workaround: create an off-screen `NSTextView` sharing the same `NSTextStorage`, set its `appearance` to `NSAppearance(named: .aqua)`, print from that. UIKit's print system uses `UIPrintInteractionController` with `UISimpleTextPrintFormatter` for simple cases or a `UIPrintPageRenderer` subclass for custom layout.

## UIKit-only capabilities

Some `UITextView` features have no `NSTextView` counterpart, mostly because they describe touch-first or post-iOS-17 interaction patterns.

**Declarative data detection.** `UITextView.dataDetectorTypes` is a single options set covering links, phone numbers, addresses, calendar events, shipment tracking, and flight numbers. Detection is automatic when `isEditable = false`. AppKit has the toggles `isAutomaticLinkDetectionEnabled` and `isAutomaticDataDetectionEnabled`, but the granular type set isn't exposed and detection has to be triggered via `checkTextInDocument:`.

**`UITextInteraction`.** A modular interaction object that adds system text gestures (cursor movement, selection handles, magnification) to *any* `UIView` conforming to `UITextInput`. There is no AppKit equivalent — `NSTextView`'s gestures are built into the view and can't be extracted onto another view.

**`UITextItem` interactions (iOS 17+).** `textView(_:primaryActionFor:defaultAction:)` and `textView(_:menuConfigurationFor:defaultMenu:)` provide rich interaction with links, attachments, and tagged ranges, including custom actions and context menus. Arbitrary ranges can be tagged with `NSAttributedString.Key.uiTextItemTag`. AppKit has only `textView(_:clickedOnLink:at:)` — much narrower.

**`UITextSelectionDisplayInteraction` (iOS 17+).** System selection UI (cursor, handles, highlights) attached to a custom view. AppKit gained `NSTextInsertionIndicator` on macOS Sonoma for cursor display, but nothing comparable for full selection UI.

**`UITextLoupeSession` (iOS 17+).** The magnifying-loupe presentation during text selection, exposed as a session API for custom views. macOS doesn't use a loupe for text selection — no equivalent exists.

## Architectural differences

A handful of structural differences shape every cross-platform editor:

**Inheritance.** AppKit: `NSObject → NSResponder → NSView → NSText → NSTextView`. UIKit: `NSObject → UIResponder → UIView → UIScrollView → UITextView`. AppKit's `NSText` base class carries RTF, font panel, ruler, speech, and field-editor concepts. UIKit's text view inherits scrolling but has no text-specific base class.

**Scrolling.** `UITextView` *is* a `UIScrollView`. It's always scrollable; set `isScrollEnabled = false` to disable. `NSTextView` is *not* a scroll view — it must be embedded in an `NSScrollView`, usually via `NSTextView.scrollableTextView()` which constructs the pair. This affects every wrapper, every layout, and every keyboard avoidance strategy.

**Text storage access.** `UITextView.textStorage` is a non-optional `NSTextStorage`. `NSTextView.textStorage` is `NSTextStorage?` — optional. Reading attributed text is `attributedText` on UIKit (a property), `attributedString()` on AppKit (a method). The optionality difference matters for porting: AppKit code has to handle `nil` storage (rare, but possible during teardown).

**Selection.** `UITextView.selectedRange` is a single `NSRange`. `NSTextView.selectedRanges` is `[NSValue]` (an array of `NSRange` boxed in `NSValue`) because AppKit supports discontiguous selection.

**Delegate richness.** `NSTextViewDelegate` has more callbacks than `UITextViewDelegate`: modify selection during change, intercept link clicks (with custom handling for non-URL link types), customize drag operations, control tooltip display, handle completions. UIKit's delegate is minimal; iOS 17's `UITextItem` interactions narrowed the gap but didn't close it.

## Writing Tools across the platforms

Both platforms support Writing Tools as of iOS 18 / macOS 15. The system view API is parallel (`writingToolsBehavior`, `writingToolsAllowedInputOptions`, `isWritingToolsActive`, matching delegate methods). Both require TextKit 2 for the inline experience.

The differences appear in custom text engines (views that don't inherit from `UITextView` / `NSTextView`):

| Aspect | UIKit | AppKit |
|--------|-------|--------|
| Coordinator class | `UIWritingToolsCoordinator` | `NSWritingToolsCoordinator` |
| Attachment | `view.addInteraction(coordinator)` | `view.writingToolsCoordinator = coordinator` |
| Preview type | `UITargetedPreview` | `NSTextPreview` |
| Path type | `[UIBezierPath]` | `[NSBezierPath]` |
| Menu integration | Automatic via `UITextInteraction` | Requires `NSServicesMenuRequestor` adoption |

macOS 26 added `automaticallyInsertsWritingToolsItems` (default true), `.writingToolsItems` for standard menu items, and a stock `NSToolbarItem` for toolbar integration. The iOS side has had Writing Tools-as-default behavior since iOS 18.

For stock views on either platform, attaching Writing Tools is one property assignment. For custom views, the work is parallel but the types are different — port carefully.

## Fallback detection

Both platforms can fall back from TextKit 2 to TextKit 1 silently when an API access flips the view. Detection differs:

- **UIKit:** check `textView.textLayoutManager == nil`. If `nil`, the view has fallen back. Set a symbolic breakpoint on `_UITextViewEnablingCompatibilityMode` to catch the moment it happens.
- **AppKit:** same check (`textLayoutManager == nil`), plus subscription notifications: `NSTextView.willSwitchToNSLayoutManagerNotification` and `NSTextView.didSwitchToNSLayoutManagerNotification`. AppKit also logs the switch to the system console.

The fallback is permanent for that view instance. Recovery means creating a new view and copying the content. AppKit's notifications are useful for instrumentation; UIKit's symbolic breakpoint is useful for hunting the offending API call.

## Cross-platform feature parity

When porting and you need to decide whether a feature is feasible on the target platform:

| Need | Platform |
|------|----------|
| Text tables | AppKit only |
| Grammar checking API | AppKit only |
| Text completion API | AppKit only |
| Services menu | AppKit only (concept doesn't exist on iOS) |
| Font panel integration | AppKit only |
| Interactive ruler | AppKit only |
| Direct RTF/RTFD file I/O | AppKit only (NSText heritage) |
| Find / replace | Both (`NSTextFinder` / `UIFindInteraction`) |
| Declarative `dataDetectorTypes` | UIKit cleaner |
| Modular text interaction (UITextInteraction) | UIKit only |
| Text item context menus | UIKit only (iOS 17+) |
| Selection display component | UIKit only (UITextSelectionDisplayInteraction) |
| Magnifying loupe | UIKit only |
| Multi-page / multi-column | AppKit better (TextKit 1, ruled out for TK2 features) |
| Built-in scrolling | UIKit (UITextView IS a UIScrollView) |
| Writing Tools (stock view) | Both |
| Writing Tools (custom view) | Both, with different coordinator types |

## Common mistakes when porting

1. **Assuming `NSTextView` scrolls itself.** It doesn't. `NSTextView` must live inside an `NSScrollView`. The convenience `NSTextView.scrollableTextView()` returns the pair correctly. Code that ports `UITextView`'s "set frame and add to view hierarchy" pattern straight across will produce a non-scrolling text view that clips its content.

2. **Touching shared field-editor properties.** On macOS, `NSTextField` shares one `NSTextView` per window as its field editor. Setting properties on the field editor leaks across all fields. Customize per-field via `textShouldBeginEditing(_:)` (set the property) and `textShouldEndEditing(_:)` (restore it), or via `windowWillReturnFieldEditor(_:to:)` to provide a per-field editor instance. And: touching `layoutManager` on a field editor flips all fields in the window to TextKit 1.

3. **Treating `tintColor` as a cross-platform cursor color.** UIKit's `tintColor` controls cursor color and selection accent. AppKit splits these: cursor is `insertionPointColor`, selection background is `selectedTextAttributes[.backgroundColor]`. They are not unified — port carefully or the AppKit cursor stays the default color.

4. **Expecting `UITextDragInteraction` to have an AppKit equivalent.** AppKit drag-and-drop uses `NSDraggingSource` / `NSDraggingDestination` adopted by the view itself, not a separate interaction object. Porting drag code is a real reimplementation.

5. **Forgetting AppKit menu validation.** `validateMenuItem(_:)` and `validateUserInterfaceItem(_:)` must be implemented for context-menu items to enable/disable correctly. UIKit's `UIEditMenuInteraction` infers state automatically. AppKit menus that "always show all items enabled" are usually missing the validation methods.

6. **Assuming `NSTextView` delegate methods always run on the main thread.** Pasteboard read/write callbacks (`textView(_:writeSelectionTo:type:)`, etc.) can fire on background threads during drag-and-drop or copy operations. Background-thread mutation of TextKit objects causes the same sporadic crashes there as anywhere else. UIKit dispatches consistently on the main thread.

7. **Auditing only the TextKit 2 surface when porting.** Both platforms inherited the full TextKit 1 surface. A port that only checks `NSTextLayoutManager` features can miss `NSTextTable`, `NSLayoutManager` glyph access, or temporary attributes that the original code depended on. Audit both stacks against the requirement set.

## References

- `/skill txt-view-picker` — choosing among SwiftUI / UIKit / AppKit text views
- `/skill txt-wrap-textview` — wrapping `UITextView` / `NSTextView` in SwiftUI
- `/skill txt-writing-tools` — Writing Tools coordinator details
- `/skill txt-fallback-triggers` — TextKit 1 fallback on either platform
- [UITextView](https://sosumi.ai/documentation/uikit/uitextview)
- [NSTextView](https://sosumi.ai/documentation/appkit/nstextview)
- [NSText](https://sosumi.ai/documentation/appkit/nstext)
- [UITextInteraction](https://sosumi.ai/documentation/uikit/uitextinteraction)
- [UIFindInteraction](https://sosumi.ai/documentation/uikit/uifindinteraction)
- [NSTextFinder](https://sosumi.ai/documentation/appkit/nstextfinder)
- [UIWritingToolsCoordinator](https://sosumi.ai/documentation/uikit/uiwritingtoolscoordinator)
- [NSWritingToolsCoordinator](https://sosumi.ai/documentation/appkit/nswritingtoolscoordinator)
