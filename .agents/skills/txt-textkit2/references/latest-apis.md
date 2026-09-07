# Latest API surface — txt-textkit2

Authored against iOS 26.x / Swift 6.x / Xcode 26.x. Last refreshed 2026-04-29 against Sosumi.

This sidecar holds the rapid-churn TextKit 2 signatures. SKILL.md owns the mental model. Refresh procedure lives in `txt-refresh-against-sosumi`. Every signature below was sourced from the corresponding sosumi.ai page on the refresh date listed; see the verification table at the bottom for URL liveness.

## Content manager

`NSTextContentManager` (UIKit, iOS 15.0+ / iPadOS 15.0+ / Mac Catalyst 15.0+ / tvOS 15.0+ / visionOS 1.0+). Abstract base; subclass `NSTextContentStorage` for attributed-string-backed content.

- `var textLayoutManagers: [NSTextLayoutManager]` — registered layout managers, since iOS 15.0
- `var primaryTextLayoutManager: NSTextLayoutManager? { get set }` — KVO-compliant; setting to a manager not in `textLayoutManagers` resets to `nil`, since iOS 15.0
- `var automaticallySynchronizesTextLayoutManagers: Bool` — default `true`, since iOS 15.0
- `var automaticallySynchronizesToBackingStore: Bool` — default `true`, since iOS 15.0
- `var hasEditingTransaction: Bool { get }` — true while inside `performEditingTransaction`, since iOS 15.0
- `func addTextLayoutManager(_ textLayoutManager: NSTextLayoutManager)` — since iOS 15.0
- `func removeTextLayoutManager(_ textLayoutManager: NSTextLayoutManager)` — since iOS 15.0
- `func enumerateTextElements(from location: (any NSTextLocation)?, options: NSTextContentManager.EnumerationOptions = [], using block: (NSTextElement) -> Bool) -> (any NSTextLocation)?` — since iOS 15.0

`NSTextContentStorage` (UIKit, iOS 15.0+). Concrete subclass of `NSTextContentManager` that wraps an `NSTextStorage` and emits `NSTextParagraph` elements.

- `var attributedString: NSAttributedString?` — content as an attributed string, since iOS 15.0
- `weak var delegate: NSTextContentStorageDelegate?` — since iOS 15.0
- `var includesTextListMarkers: Bool` — controls whether list markers appear in paragraphs, since iOS 15.0
- `func textElement(for range: NSTextRange) -> NSTextElement?` — since iOS 15.0
- `func attributedString(for textElement: NSTextElement) -> NSAttributedString?` — since iOS 15.0
- `func adjustedRange(from textRange: NSTextRange, forEditingTextSelection: Bool) -> NSTextRange?` — since iOS 15.0
- `func location(_ location: any NSTextLocation, offsetBy offset: Int) -> (any NSTextLocation)?` — since iOS 15.0
- `func offset(from: any NSTextLocation, to: any NSTextLocation) -> Int` — since iOS 15.0

`NSTextContentStorageDelegate`:

- `func textContentStorage(_ storage: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph?` — display-only paragraph substitution, since iOS 15.0

## Layout manager

`NSTextLayoutManager` (UIKit, iOS 15.0+). Replaces `NSLayoutManager`; element- and fragment-based; one container only.

- `weak var textContentManager: NSTextContentManager? { get }` — since iOS 15.0
- `var textContainer: NSTextContainer?` — exactly one container, since iOS 15.0
- `var textViewportLayoutController: NSTextViewportLayoutController { get }` — since iOS 15.0
- `var textSelectionNavigation: NSTextSelectionNavigation { get }` — since iOS 15.0
- `var textSelections: [NSTextSelection]` — since iOS 15.0
- `var usageBoundsForTextContainer: CGRect { get }` — estimate while scrolling; refines as fragments lay out, since iOS 15.0. The value is unstable during a viewport pass: it shifts as the controller advances and re-estimates unmeasured ranges. Reading it directly into a `UIScrollView.contentSize` produces visible scroll-bar jitter (Apple's TextEdit demonstrates this). The supported pattern is to read it once per viewport pass, inside `textViewportLayoutControllerDidLayout(_:)`, and write it to content size only there.
- `func enumerateTextLayoutFragments(from location: (any NSTextLocation)?, options: NSTextLayoutFragment.EnumerationOptions = [], using block: (NSTextLayoutFragment) -> Bool) -> (any NSTextLocation)?` — since iOS 15.0
- `func setRenderingAttributes(_ renderingAttributes: [NSAttributedString.Key : Any], for textRange: NSTextRange)` — since iOS 15.0
- `func addRenderingAttribute(_ name: NSAttributedString.Key, value: Any?, for textRange: NSTextRange)` — since iOS 15.0
- `func removeRenderingAttribute(_ name: NSAttributedString.Key, for textRange: NSTextRange)` — since iOS 15.0
- `func enumerateRenderingAttributes(from location: any NSTextLocation, reverse: Bool, using block: (NSTextLayoutManager, [NSAttributedString.Key : Any], NSTextRange) -> Bool)` — since iOS 15.0
- `func invalidateLayout(for textRange: NSTextRange)` — since iOS 15.0
- `func invalidateRenderingAttributes(for textRange: NSTextRange)` — since iOS 15.0
- `func ensureLayout(for textRange: NSTextRange)` and `func ensureLayout(for bounds: CGRect)` — since iOS 15.0. Calling `ensureLayout(for: documentRange)` is a documented trap; Apple DTS confirms the call can take seconds because it materializes every fragment in the document. The supported scroll-to-target pattern is the four-step sequence: identify the target range, `ensureLayout(for:)` for that range only, read `layoutFragmentFrame` from the resulting fragment, then `adjustViewport(byVerticalOffset:)`.

`NSTextLayoutManagerDelegate`:

- `func textLayoutManager(_ manager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation, in textElement: NSTextElement) -> NSTextLayoutFragment` — supply a custom layout fragment, since iOS 15.0
- `func textLayoutManager(_ manager: NSTextLayoutManager, shouldBreakLineBefore location: any NSTextLocation, hyphenating: Bool) -> Bool` — soft break control, since iOS 15.0
- `func textLayoutManager(_ manager: NSTextLayoutManager, renderingAttributesForLink link: Any, at location: any NSTextLocation, defaultAttributes: [NSAttributedString.Key : Any]) -> [NSAttributedString.Key : Any]?` — link rendering, since iOS 15.0

## Layout fragments

`NSTextLayoutFragment` (UIKit, iOS 15.0+). One per element (typically one per paragraph). Owns the line fragments inside it.

- `var textElement: NSTextElement? { get }` — since iOS 15.0
- `var rangeInElement: NSTextRange { get }` — range relative to document origin, since iOS 15.0
- `var textLineFragments: [NSTextLineFragment] { get }` — since iOS 15.0
- `var layoutFragmentFrame: CGRect { get }` — fragment tile rect, since iOS 15.0
- `var renderingSurfaceBounds: CGRect { get }` — drawing extent; can exceed `layoutFragmentFrame`, since iOS 15.0
- `var leadingPadding: CGFloat`, `var trailingPadding: CGFloat`, `var topMargin: CGFloat`, `var bottomMargin: CGFloat` — since iOS 15.0
- `var state: NSTextLayoutFragment.State { get }` — layout-information state, since iOS 15.0
- `var textAttachmentViewProviders: [NSTextAttachmentViewProvider] { get }` — since iOS 15.0
- `weak var textLayoutManager: NSTextLayoutManager? { get }` — since iOS 15.0
- `var layoutQueue: DispatchQueue?` — since iOS 15.0
- `func draw(at point: CGPoint, in context: CGContext)` — since iOS 15.0
- `func frameForTextAttachment(at location: any NSTextLocation) -> CGRect` — since iOS 15.0
- `func invalidateLayout()` — since iOS 15.0

`NSTextLayoutFragment.EnumerationOptions` (OptionSet, iOS 15.0+):

- `.ensuresLayout` — force layout during enumeration; expensive over large ranges
- `.ensuresExtraLineFragment` — synthesize the trailing empty line after `\n`
- `.estimatesSize` — use estimated geometry; cheap
- `.reverse` — enumerate backwards from the location

`NSTextLineFragment` (UIKit, iOS 15.0+). Visual line within a layout fragment.

- `var attributedString: NSAttributedString { get }` — line's source string, since iOS 15.0
- `var characterRange: NSRange { get }` — local to the fragment's own attributed string, NOT document-relative, since iOS 15.0
- `var typographicBounds: CGRect { get }` — line dimensions for stacking, since iOS 15.0
- `var glyphOrigin: CGPoint { get }` — leftmost glyph origin in line-fragment coords, since iOS 15.0
- `func locationForCharacter(at index: Int) -> CGPoint` — since iOS 15.0
- `func characterIndex(for point: CGPoint) -> Int` — since iOS 15.0
- `func draw(at point: CGPoint, in context: CGContext)` — since iOS 15.0

## Viewport

`NSTextViewportLayoutController` (UIKit, iOS 15.0+). Orchestrator for visible-region layout. One per layout manager.

- `weak var textLayoutManager: NSTextLayoutManager? { get }` — since iOS 15.0
- `weak var delegate: NSTextViewportLayoutControllerDelegate?` — since iOS 15.0
- `var viewportBounds: CGRect { get }` — visible bounds plus overdraw, since iOS 15.0
- `var viewportRange: NSTextRange? { get }` — text range currently visible, since iOS 15.0
- `init(textLayoutManager: NSTextLayoutManager)` — since iOS 15.0
- `func layoutViewport()` — synchronous viewport layout pass, since iOS 15.0
- `func relocateViewport(to verticalLocation: any NSTextLocation) -> CGFloat` — since iOS 15.0
- `func adjustViewport(byVerticalOffset verticalOffset: CGFloat)` — since iOS 15.0. Used as the final step of the supported scroll-to-target sequence (range-scoped `ensureLayout` → read fragment frame → `adjustViewport`). Cheap relative to a full-document `ensureLayout` because the work is bounded by the distance from the current viewport, not the document size.

`NSTextViewportLayoutControllerDelegate`:

- `func viewportBounds(for controller: NSTextViewportLayoutController) -> CGRect` — supply viewport bounds, since iOS 15.0
- `func textViewportLayoutControllerWillLayout(_ controller: NSTextViewportLayoutController)` — since iOS 15.0
- `func textViewportLayoutController(_ controller: NSTextViewportLayoutController, configureRenderingSurfaceFor fragment: NSTextLayoutFragment)` — position views/layers per visible fragment, since iOS 15.0
- `func textViewportLayoutControllerDidLayout(_ controller: NSTextViewportLayoutController)` — since iOS 15.0. The correct place to push `usageBoundsForTextContainer` into a host scroll view's content size; the value is settled here for the duration of one pass.

## Ranges and locations

`NSTextLocation` (UIKit protocol, iOS 15.0+). Conforms to `NSObjectProtocol`. Required:

- `func compare(_ location: any NSTextLocation) -> ComparisonResult` — logical ordering, since iOS 15.0

`NSTextRange` (UIKit, iOS 15.0+). Object-based half-open range over locations.

- `init(location: any NSTextLocation)` — empty range at a location, since iOS 15.0
- `init?(location start: any NSTextLocation, end: (any NSTextLocation)?)` — since iOS 15.0
- `var location: any NSTextLocation { get }` — since iOS 15.0
- `var endLocation: any NSTextLocation { get }` — since iOS 15.0
- `var isEmpty: Bool { get }` — since iOS 15.0
- `func intersects(_ textRange: NSTextRange) -> Bool` — since iOS 15.0
- `func intersection(_ textRange: NSTextRange) -> NSTextRange?` — since iOS 15.0
- `func union(_ textRange: NSTextRange) -> NSTextRange` — since iOS 15.0
- `func contains(_ location: any NSTextLocation) -> Bool`
- `func contains(_ textRange: NSTextRange) -> Bool` — since iOS 15.0

`NSTextElement` (UIKit, iOS 15.0+). Abstract base.

- `init(textContentManager: NSTextContentManager?)` — since iOS 15.0
- `weak var textContentManager: NSTextContentManager? { get }` — since iOS 15.0
- `var elementRange: NSTextRange?` — since iOS 15.0
- `var childElements: [NSTextElement] { get }` — since iOS 15.0
- `weak var parent: NSTextElement? { get }` — Sosumi names this `parent` (the SKILL.md previously called it `parentElement`; flagged below), since iOS 15.0
- `var isRepresentedElement: Bool { get }` — since iOS 15.0

`NSTextParagraph` (UIKit, iOS 15.0+). The only element subclass guaranteed to work end-to-end.

- `init(attributedString: NSAttributedString?)` — since iOS 15.0
- `var attributedString: NSAttributedString { get }` — since iOS 15.0
- `var paragraphContentRange: NSTextRange? { get }` — range without separator, since iOS 15.0
- `var paragraphSeparatorRange: NSTextRange? { get }` — separator range, since iOS 15.0

`NSTextSelection` (UIKit, iOS 15.0+). Possibly noncontiguous selection over `NSTextRange`s.

- `init(_ location: any NSTextLocation, affinity: NSTextSelection.Affinity)` — since iOS 15.0
- `init(range: NSTextRange, affinity: NSTextSelection.Affinity, granularity: NSTextSelection.Granularity)` — since iOS 15.0
- `init(_ ranges: [NSTextRange], affinity: NSTextSelection.Affinity, granularity: NSTextSelection.Granularity)` — since iOS 15.0
- `var textRanges: [NSTextRange] { get }` — since iOS 15.0
- `var granularity: NSTextSelection.Granularity { get }` — since iOS 15.0
- `var affinity: NSTextSelection.Affinity { get }` — since iOS 15.0
- `var isLogical: Bool { get }` — logical vs. visual interpretation, since iOS 15.0
- `var anchorPositionOffset: CGFloat` — offset from line-fragment start, since iOS 15.0
- `func textSelection(with ranges: [NSTextRange]) -> NSTextSelection` — derive a sub-selection, since iOS 15.0

## Editing transaction

All mutations on the wrapped backing store go through the editing transaction so element regeneration and layout invalidation fire. Direct `NSTextStorage` mutations outside the wrapper produce stale fragments.

- `NSTextContentManager.performEditingTransaction(_ transaction: () -> Void)` — runs the closure as one unit; element regeneration and layout invalidation happen at close, since iOS 15.0
- `NSTextContentManager.hasEditingTransaction: Bool { get }` — read inside delegate callbacks to detect transaction context, since iOS 15.0

```swift
contentStorage.performEditingTransaction {
    textStorage.replaceCharacters(in: range, with: newText)
}
```

## Discrepancies flagged on this refresh

1. **`documentRange`.** Used in SKILL.md on both `NSTextLayoutManager` and `NSTextContentManager`. Sosumi's processed class pages do not list it under any topic group, and `…/documentrange` symbol URLs return 404. The property is a real part of Apple's TextKit 2 surface (it is the canonical way to reach the start/end of the document and is used in Apple sample code), so this is treated as a Sosumi indexing gap, not an API removal. Maintainer should verify against Xcode-bundled docs (`xcrun mcpbridge` → DocumentationSearch) before any deletion.
2. **`NSTextElement.parent` vs `parentElement`.** SKILL.md has historically used `parentElement`; the live Sosumi page names the property `parent`. Confirmed via `…/nstextelement/parent` returning 200 and `…/parentelement` returning 404. Update SKILL.md prose on the next content edit.
3. **`NSTextContentStorage.textStorage`.** Referenced in SKILL.md as the bridge to the wrapped `NSTextStorage`. The Sosumi class page does not list `textStorage` among its instance properties (it lists `attributedString`, `delegate`, `includesTextListMarkers`). The property exists in Apple's headers; this is a Sosumi indexing gap. Cross-verify with `xcrun mcpbridge` before removing.
4. **`enumerateTextElements(from:options:using:)` symbol URL 404.** The class-level page on `NSTextContentManager` references the method via its `EnumerationOptions` type, but the deep-link symbol URL doesn't resolve. Sosumi indexing gap — the method exists and is documented at the class level.

## Signatures verified against Sosumi

| URL | Status | Last fetched |
|---|---|---|
| https://sosumi.ai/documentation/uikit/nstextlayoutmanager | 200 | 2026-04-29 |
| https://sosumi.ai/documentation/uikit/nstextcontentmanager | 200 | 2026-04-29 |
| https://sosumi.ai/documentation/uikit/nstextcontentstorage | 200 | 2026-04-29 |
| https://sosumi.ai/documentation/uikit/nstextlayoutfragment | 200 | 2026-04-29 |
| https://sosumi.ai/documentation/uikit/nstextlayoutfragment/enumerationoptions | 200 | 2026-04-29 |
| https://sosumi.ai/documentation/uikit/nstextlinefragment | 200 | 2026-04-29 |
| https://sosumi.ai/documentation/uikit/nstextviewportlayoutcontroller | 200 | 2026-04-29 |
| https://sosumi.ai/documentation/uikit/nstextelement | 200 | 2026-04-29 |
| https://sosumi.ai/documentation/uikit/nstextelement/parent | 200 | 2026-04-29 |
| https://sosumi.ai/documentation/uikit/nstextparagraph | 200 | 2026-04-29 |
| https://sosumi.ai/documentation/uikit/nstextrange | 200 | 2026-04-29 |
| https://sosumi.ai/documentation/uikit/nstextrange/init(location:end:) | 200 | 2026-04-29 |
| https://sosumi.ai/documentation/uikit/nstextlocation | 200 | 2026-04-29 |
| https://sosumi.ai/documentation/uikit/nstextlocation/compare(_:) | 200 | 2026-04-29 |
| https://sosumi.ai/documentation/uikit/nstextselection | 200 | 2026-04-29 |
| https://sosumi.ai/documentation/uikit/nstextselectionnavigation | 200 | 2026-04-29 |
| https://sosumi.ai/documentation/uikit/nstextlayoutmanagerdelegate | 200 | 2026-04-29 |
| https://sosumi.ai/documentation/uikit/nstextlayoutmanagerdelegate/textlayoutmanager(_:textlayoutfragmentfor:in:) | 200 | 2026-04-29 |
| https://sosumi.ai/documentation/uikit/nstextcontentstoragedelegate | 200 | 2026-04-29 |
| https://sosumi.ai/documentation/uikit/nstextcontentstoragedelegate/textcontentstorage(_:textparagraphwith:) | 200 | 2026-04-29 |
| https://sosumi.ai/documentation/uikit/nstextcontentmanager/performeditingtransaction(_:) | 200 | 2026-04-29 |
| https://sosumi.ai/documentation/uikit/nstextcontentmanager/addtextlayoutmanager(_:) | 200 | 2026-04-29 |
| https://sosumi.ai/documentation/uikit/nstextcontentmanager/primarytextlayoutmanager | 200 | 2026-04-29 |
| https://sosumi.ai/documentation/uikit/nstextlayoutmanager/setrenderingattributes(_:for:) | 200 | 2026-04-29 |
| https://sosumi.ai/documentation/uikit/nstextlayoutmanager/enumeratetextlayoutfragments(from:options:using:) | 200 | 2026-04-29 |
| https://sosumi.ai/documentation/uikit/nstextlayoutmanager/textselections | 200 | 2026-04-29 |
| https://sosumi.ai/documentation/uikit/nstextlayoutmanager/usageboundsfortextcontainer | 200 | 2026-04-29 |
| https://sosumi.ai/documentation/uikit/nstextlayoutmanager/textcontainer | 200 | 2026-04-29 |
| https://sosumi.ai/documentation/uikit/nstextviewportlayoutcontroller/layoutviewport() | 200 | 2026-04-29 |
| https://sosumi.ai/documentation/uikit/nstextlayoutfragment/layoutfragmentframe | 200 | 2026-04-29 |
| https://sosumi.ai/documentation/uikit/nstextlayoutfragment/textlinefragments | 200 | 2026-04-29 |
| https://sosumi.ai/documentation/uikit/nstextlayoutfragment/renderingsurfacebounds | 200 | 2026-04-29 |
| https://sosumi.ai/documentation/uikit/nstextlinefragment/typographicbounds | 200 | 2026-04-29 |
| https://sosumi.ai/documentation/uikit/nstextlinefragment/characterrange | 200 | 2026-04-29 |
| https://sosumi.ai/documentation/uikit/nstextcontentmanager/documentrange | 404 | 2026-04-29 |
| https://sosumi.ai/documentation/uikit/nstextcontentmanager/enumeratetextelements(from:options:using:) | 404 | 2026-04-29 |
| https://sosumi.ai/documentation/uikit/nstextcontentstorage/textstorage | 404 | 2026-04-29 |
| https://sosumi.ai/documentation/uikit/nstextelement/parentelement | 404 | 2026-04-29 |
