# Form Validation

Five patterns, from the least to the most machinery. **Choose the simplest one
that solves your case**; moving up a level unnecessarily is the usual mistake.

| Pattern | When |
|---|---|
| 1. Computed Property | One form, two or three fields |
| 2. Error Summary | The user must see every error at once |
| 3. Field-Specific Error | Long forms where the failing field must be identified |
| 4. Extracted Form Type | As soon as you want **tests** for validation |
| 5. Property Wrappers | Many forms with repeated rules |

---

## 1. Computed Property

The minimum that works. Derive, don’t store.

```swift
struct NewNoteScreen: View {
    @State private var title = ""

    private var isFormValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form { TextField("Title", text: $title) }
            .toolbar {
                Button("Crear") { /* … */ }.disabled(!isFormValid)
            }
    }
}
```

## 2. Error Summary

An array of errors recalculated on submission. Useful when the user needs to
see every error at once.

```swift
@State private var errors: [String] = []

private func validate() -> Bool {
    errors = []
    if title.isEmptyOrWhitespace { errors.append("The title is required.") }
    if folder == nil            { errors.append("Choose a destination folder.") }
    return errors.isEmpty
}

// In the body:
if !errors.isEmpty {
    VStack(alignment: .leading, spacing: 4) {
        ForEach(errors, id: \.self) { Text($0).foregroundStyle(.red) }
    }
}
```

## 3. Field‑Specific Error

The same mechanism, indexed by field so the message can be rendered beneath the
failing control.

```swift
enum NoteField: Hashable { case title, folder }

@State private var fieldErrors: [NoteField: String] = [:]

// In the body, next to the field:
TextField("Title", text: $title)
if let message = fieldErrors[.title] {
    Text(message).font(.caption).foregroundStyle(.red)
}
```

On macOS, combine it with `@FocusState` to focus the first invalid field. Users
should not have to search for it in a long form.

## 4. Extract the Form into a Type: The Important Pattern

**As soon as validation deserves a test, take it out of the view.** Not for purity:
because a validation rule inside `body` can only be tested by launching the UI.

```swift
struct NewNoteForm {
    var title: String = ""
    var folder: URL?

    var isValid: Bool { validate().isEmpty }

    func validate() -> [NoteField: String] {
        var errors: [NoteField: String] = [:]
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors[.title] = "The title is required."
        } else if title.contains("/") {
            errors[.title] = "The title cannot contain “/” because it is used as a filename."
        }
        if folder == nil { errors[.folder] = "Choose a destination folder." }
        return errors
    }
}
```

```swift
struct NewNoteScreen: View {
    @State private var form = NewNoteForm()

    var body: some View {
        Form {
            TextField("Title", text: $form.title)
        }
        .toolbar { Button("Crear") { /* … */ }.disabled(!form.isValid) }
    }
}
```

And the test, without UI:

```swift
@Test("A title containing a slash is rejected because it is a filename")
func rejectsSlashInTitle() {
    var form = NewNoteForm(title: "notes/2026", folder: URL(filePath: "/tmp"))
    #expect(form.validate()[.title] != nil)
}
```

The example rule—prohibiting `/`—is **domain-specific**, not cosmetic: in an
app whose model consists of files, the title *is* the filename. That is exactly
the kind of rule worth testing.

## 5. Property Wrappers

Inspired by ASP.NET’s *data annotations*: declare the rule next to the property.

```swift
@propertyWrapper
struct NonEmpty {
    private var value: String = ""
    private let message: String
    var error: String?

    init(wrappedValue: String, _ message: String) {
        self.message = message
        self.wrappedValue = wrappedValue
    }

    var wrappedValue: String {
        get { value }
        set {
            value = newValue
            error = newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? message : nil
        }
    }
}

struct LoginForm {
    @NonEmpty("Username is required") var username: String = ""
    @NonEmpty("The password is required") var password: String = ""
}
```

**This pays off only when many forms repeat the same rules.** With two forms, it
adds more obscurity than it removes. It also complicates collecting every error
at once: you must either reflect over the type or maintain a separate registry.
Start with pattern 4 and move to 5 only when repetition becomes painful.

---

## Rules

1. **Derive, don’t store.** `isValid` is a computed property, never a `@State`
   that you have to remember to refresh. See
   [antipatterns.md](antipatterns.md#storing-what-can-be-derived).
2. **Presentation validation lives in the view or its form type; domain validation
   lives in the model.** “This field isn’t empty” is presentation. “Two notes with
   the same name in the same folder are not allowed” is domain, and belongs in the
   store.
3. **Do not validate on every keystroke** if the message will be distracting.
   Validate when focus leaves the field or on submission; after that, live
   validation is appropriate.

## Source

- [The Ultimate Guide to Validation Patterns in SwiftUI](https://azamsharp.com/2024/12/18/the-ultimate-guide-to-validation-patterns-in-swiftui.html)
