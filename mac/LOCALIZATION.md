# Localizing Zshell

Zshell follows the macOS language selected by the user, including the per-app
language in System Settings. Users can also choose a language from
**Zshell → Settings → General → Language**. Changes apply immediately in the
running app, preserving terminal sessions, jobs, and Vim command searches.
**System Default** restores the global macOS language order. English is the
development language. The currently maintained localizations are:

| Language | Identifier |
| --- | --- |
| English | `en` |
| Chinese (Simplified) | `zh-Hans` |
| Japanese | `ja` |

## Translate existing text

Open `mac/zshell.xcodeproj` from the repository root in Xcode, select `Localizable.xcstrings`, choose a
language, and edit its translation. Xcode keeps placeholders, plural variants,
and translation state visible. The other catalogs cover macOS-owned UI:

- `InfoPlist.xcstrings` — privacy permission text.
- `ServicesMenu.xcstrings` — Zshell’s Finder Services menu item.

Keep placeholders such as `%@` and `%lld` intact. Preserve product and
technology names such as Zshell, Git, Finder, and VS Code, as well as keyboard
shortcut symbols. Translation-only pull requests are welcome.

For work outside Xcode, use **Product → Export Localizations…** to produce
XLIFF, then **Product → Import Localizations…** when the translation is ready.
XLIFF is the easiest way to send a language to a translator without exposing
the source code.

## Add a language

1. In the project editor, add the language under **Info → Localizations**.
2. Add that language to all three String Catalogs.
3. Translate every entry, including plural variants and the privacy prompt.
4. Run the app in that language and check menus, settings, the sidebars,
   dialogs, and `zshell +themes`.
5. Add the language and identifier to the table above.

## Add localizable text in Swift

SwiftUI string literals are extracted automatically:

```swift
Button("Create New Branch…") {
    createBranch()
}
```

When an API requires a runtime `String`, use `String(localized:comment:)`.
Describe placeholders in the comment when their meaning is not obvious:

```swift
let message = String(
    localized: "Choose the directory for “\(project.name)”.",
    comment: "The placeholder is the project name."
)
```

Use complete sentences instead of assembling translated fragments. Put
count-dependent grammar in a plural variant in `Localizable.xcstrings`. Mark
user content, file names, terminal output, and other non-language data as
verbatim so it is not treated as a lookup key:

```swift
Text(verbatim: file.path)
```

The build has string extraction enabled. After adding source text, build once,
then translate the new entry in `Localizable.xcstrings`.

## Test a localization

In Xcode, choose **Product → Scheme → Edit Scheme… → Run → Options**, then set
**App Language** and **App Region**. Test English, Simplified Chinese, and
Japanese independently. Also use the in-app picker to switch between all four
options and confirm that **System Default** follows the user’s macOS preference
immediately. Keep a terminal job running while switching and confirm its PID,
contents, and selection remain intact. Check the settings sidebar, menu bar,
workspace controls, and the visible Vim command list without reopening them.

`AppLocalization` resolves an explicit `.lproj` bundle because Foundation caches
the main bundle’s language. The app’s `String(localized:comment:)` overload keeps
String Catalog extraction and interpolation while using that current bundle.
Existing SwiftUI hosts receive the current locale without changing view identity.
AppKit views must refresh stored labels on `AppLocalization.didChange` or their
existing settings update path; never cache translated strings across languages.
System-owned privacy prompts and Finder Services remain managed by macOS.

Run `python3 mac/tests/test_app_localization.py` for the production catalog’s
language switching, system fallback, interpolation, and Vim search regression.
