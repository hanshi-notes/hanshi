# Text Editing on macOS

> **Scope.** The `apple-text` skills cover the *mechanics* — TextKit 2 fragment geometry,
> layout invalidation, `NSTextStorage`, AppKit vs UIKit. Install them
> ([SKILL.md](../SKILL.md)) and do not look for that here. This document is the
> **decision layer**: which text stack to build on, how to know which one you are actually
> running, and where to put the parse.

---

## 1. Know Which TextKit You Are On — It Is Not a Given

Before any architectural question, a mechanical one, because it silently invalidates the
answer to everything else.

**Verified** (macOS 15.7.9, one fresh `NSTextView` per probe, reading exactly one property):

| Probe | Result |
|---|---|
| A fresh `NSTextView(frame:)` | **TextKit 2** |
| …after reading `.layoutManager` **once** | **TextKit 1** |
| …after reading `.textStorage` | TextKit 2 — safe |
| …after reading `.textContainer` | TextKit 2 — safe |
| Can it be switched back? | **No. One-way** |

An `NSTextView` starts on TextKit 2 and **falls back to TextKit 1 the first time anything
reads `.layoutManager`** — permanently, at runtime, with no warning, no log line and no
API to undo it. One line of copied Stack Overflow, one helper written before 2021, one
dependency reaching for the layout manager, and the app you believe is TextKit 2 is not.

The probe itself demonstrates how easy it is: an expression that reads `textLayoutManager`
and then `layoutManager` reports both as present, because evaluating the second half
performs the downgrade.

**So assert it.** A one-line check in the view's setup is the difference between a design
decision and an accident:

```swift
assert(textView.textLayoutManager != nil,
       "This view fell back to TextKit 1 — something read .layoutManager")
```

Corollary for the code you write around it: **reach for `textLayoutManager`,
`textContentStorage` and `textContainer`, never `layoutManager`**, unless TextKit 1 is the
deliberate choice below.

---

## 2. The Decision: TextKit 1 or TextKit 2

The obvious answer — "2, it is newer" — is not what shipping editors chose, and the
disagreement is informative enough to record rather than resolve by preference.

| App / author | Choice | Stated reason |
|---|---|---|
| **STTextView** (Krzyzanowski, 4+ yrs on TextKit 2) | TextKit 2 | Built it, and concludes the API "and its implementation are lacking and unexpectedly difficult to use correctly" |
| **Paper** (11 yrs, shipping) | TextKit 1 | Same concepts, older but predictable API; iOS/macOS parity |
| **OpenMark** | TextKit 1 | TextKit 2 reliability in selection, undo and large-document performance during 2024–25 |
| **CueCam 2.0** | TextKit 2 | Needed STTextView to absorb the reverse-engineering, and still had to draw its own selection highlight |

**The concrete failure mode**, and the reason it is not a matter of taste: TextKit 2 lays
out only the viewport and *estimates* the rest of the document's height. As the viewport
moves, `NSTextLayoutManager.usageBoundsForTextContainer` changes substantially, so the
scroller jumps and resizes while the user scrolls. Apple's answer to the report was that
this is "correct and as-designed — the viewport-based layout in TextKit 2 doesn't require
that the document is fully laid out." TextEdit exhibits it too, which is the tell that it
is the framework and not your code.

Jumping to the end of a document therefore needs a manual dance — force layout at the end,
read back a height that typically overshoots, resize the content view, then reposition the
viewport by hand.

**A second gap worth knowing before you design around it**: `NSTextContentManager` reads
like an abstraction over document storage, and is not one in practice. `NSTextView` works
only with `NSTextContentStorage` — **verified**: the content manager on a TextKit 2
`NSTextView` is `NSTextContentStorage`, and Apple's forums confirm no other implementation
is supported. Custom `NSTextElement` subclasses that do not inherit `NSTextParagraph`
trigger runtime assertions. If your plan was to back the editor with your own document
model behind that protocol, it does not work; you will be holding an `NSTextStorage`.

**How to decide.** TextKit 2 for a *viewer* or a bounded editing surface where the
document is small enough that the estimation never shows. TextKit 1 when you are shipping
a general text editor over documents of arbitrary size and cannot afford to fight scroller
behaviour that Apple considers correct. Either way, §1 applies: pick one and assert it.

**Do not treat this as settled.** It is the single decision most likely to have changed by
the time you read it; re-check the viewport behaviour against the current OS before
inheriting the conclusion.

---

## 3. Where the Parse Lives: Two Tiers of Attributes

For a Markdown or syntax-highlighted editor, the architectural question is what
`NSAttributedString` is holding. The pattern that survives is **two independent tiers on
the same storage**:

| Tier | What it is | Affects rendering? |
|---|---|---|
| **Meta attributes** | Custom keys recording what the syntax *is* — heading level, emphasis span, code fence. A flattened AST living in the text storage | No |
| **Styling attributes** | `.font`, `.foregroundColor`, `.paragraphStyle` — **derived from** the meta tier | Yes |

This is [*Storing What Can Be Derived*](antipatterns.md#storing-what-can-be-derived)
applied to text: the parse is stored because re-deriving it per keystroke is too
expensive, and the appearance is derived because caching it creates a second truth that
drifts when the theme changes.

What the split buys, beyond highlighting: heading navigation, an outline menu, "toggle
bold" that can tell whether the selection is already emphasised, chapter reordering and
export to RTF/HTML/DOCX are all traversals of the meta tier. Without it each of those
re-parses the document.

Three edit events, three amounts of work:

| Event | Meta tier | Styling tier |
|---|---|---|
| Document opened | full parse | full apply |
| Text changed | reparse affected range | apply to that range |
| Theme/setting changed | **untouched** | full re-apply |

**Typing is the case that decides whether the editor feels fast.** Re-parsing the document
per keystroke is not viable and re-parsing nothing is wrong. The workable heuristic:
inspect the typed character and its neighbours — if it is a Markdown symbol, or lands next
to one, reparse the paragraph; otherwise let the view's typing attributes carry it and do
nothing. Apply layout-affecting attributes (font, paragraph style) inside a
`beginEditing`/`endEditing` transaction and the purely decorative ones outside it, so a
colour change does not trigger relayout.

Cache the `NSFont`, `NSColor` and `NSParagraphStyle` instances across keystrokes. They are
immutable and comparatively expensive; rebuilding them per edit is measurable.

---

## 4. Traps With a Known Cost

**Links are accessibility children, computed on demand.** **Verified**: an `NSTextView`
whose storage holds *n* `.link` attributes returns exactly *n* `accessibilityChildren()`,
built from the text storage each time it is asked. Nothing caches. The reported
consequence — which needs a live accessibility hierarchy to observe, so it is cited rather
than measured here — is that showing an `NSPopover` positioned relative to such a text
view walks that hierarchy repeatedly, and the cost grows with the link count: roughly 4
calls for 1 link, 301 for 100. If a preview or hover popover feels slow over a
link-dense document, this is the first thing to check, and overriding
`accessibilityParent` on the popover severs the traversal.

**⌫ and ⌥⌫ never reach `performKeyEquivalent(_:)`.** They arrive through
`doCommand(by:)` → `deleteBackward(_:)` / `deleteWordBackward(_:)`, while other
combinations (⌘⌫ among them) do go through `performKeyEquivalent` first. Binding a menu
item to plain backspace therefore behaves differently from every other shortcut in the
app. Reported behaviour, not reproduced here — it needs real key events.

**`usesFontPanel` on a large plain-text document** is reported to degrade performance. For
a source editor the font panel is meaningless anyway; turning it off costs nothing.

**Attribute-only changes do not get undo for free.** `NSTextView` registers undo for text
edits, not for attribute mutations you make on the storage yourself. See
[undo.md](undo.md) — the `UndoManager` is a system responsibility, and syntax highlighting
must not land in it at all.

---

## 5. Claims That Did Not Reproduce Here

Recorded because both are widely linked, and because this skill's rule is to check a
claim rather than repeat it.

- **"Re-applying attributes moves the insertion point."** Setting `.foregroundColor` and
  `.font` over the whole storage of an `NSTextView` with a collapsed selection at offset
  20 left the selection at 20, with and without a `beginEditing`/`endEditing` transaction.
  If the bug is live it needs a condition this probe did not create — a real window and
  first responder, or a specific edit sequence. Do not design around it without
  reproducing it first.
- **"A plain-text `NSTextView` does not handle `PasteboardType.string`."** With
  `isRichText = false`, `readablePasteboardTypes` **begins** with `NSStringPboardType`,
  and lists more types than the rich-text view does. Whatever the original report was,
  the type is advertised on this OS.

---

## 6. Getting Text Out: the Markdown UTI Does Not Pay

Exporting `net.daringfireball.markdown` on the pasteboard is the principled choice and
loses. Receiving apps prefer `public.rtf` when both are offered, and Pages inserts the raw
Markdown source instead of converting it, so a Markdown-first editor that advertises its
own UTI produces *worse* paste results than one that does not.

The workable compromise is to write **both** representations — Markdown for tools that ask
for it explicitly, RTF for everything else — and accept that Markdown-to-Markdown transfer
between editors goes through RTF. `NSAttributedString` is effectively the programmatic
form of RTF, so that representation is nearly free to produce.

---

## Sources

- [TextKit 2: The Promised Land](https://blog.krzyzanowskim.com/2025/08/14/textkit-2-the-promised-land/),
  Marcin Krzyzanowski (author of STTextView) — §2's failure mode, Apple's "as-designed"
  response, and the `NSTextContentManager` limitation.
- [Paper: Internals](https://paper.pro/internals) — §3's two-tier attribute architecture,
  the typing heuristic, and §6's pasteboard finding, from an editor shipped for 11 years.
- [Why We Built OpenMark](https://openmarkapp.com/blog/why-we-built-openmark) and
  [CueCam 2.0](https://cuecam-presenter.com/newsroom/cuecam-2.0--markdown-ish-webcam-presentations)
  — two more data points for §2's table, landing on opposite sides.
- [Christian Tietze's `nstextview` archive](https://christiantietze.de/posts/tags/nstextview/)
  — the source for §4 and for the two claims in §5. Twenty-plus documented AppKit
  behaviours; worth reading in full before building an editor.
- §1's fallback table and the link/accessibility count in §4 are measured in this
  repository's toolchain.
