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
| Chinese (Traditional) | `zh-Hant` |
| Japanese | `ja` |
| Korean | `ko` |
| French | `fr` |
| German | `de` |
| Spanish | `es` |
| Portuguese (Brazil) | `pt-BR` |
| Italian | `it` |
| Dutch | `nl` |
| Russian | `ru` |
| Arabic | `ar` |
| Thai | `th` |
| Indonesian | `id` |
| Vietnamese | `vi` |
| Turkish | `tr` |

The 17 languages match Zisla. Regional preferences resolve to their supported
language: for example, `fr-CA` uses French and `pt-PT` uses Brazilian Portuguese.
Chinese preferences honor an explicit script; otherwise Taiwan, Hong Kong, and
Macao use Traditional Chinese, while other Chinese preferences use Simplified
Chinese. The picker displays language names in their own language.

## Translate existing text

Open `mac/zshell.xcodeproj` from the repository root in Xcode, select `Localizable.xcstrings`, choose a
language, and edit its translation. Xcode keeps placeholders, plural variants,
and translation state visible. The other catalogs cover macOS-owned UI:

- `InfoPlist.xcstrings` — privacy permission text.
- `ServicesMenu.xcstrings` — Zshell’s Finder Services menu item.

The Zshell bundle name and display name are brands and are not translated.
All other translatable entries must have a translation in every maintained
language. Keep translations in the catalogs; no network translation service
is involved when the app runs.

Keep placeholders such as `%@` and `%lld` intact in every plural variant. Use
the language's plural rules, including Russian's one/few/many/other and Arabic's
zero/one/two/few/many/other forms. Preserve product and
technology names such as Zshell, Git, Finder, and VS Code, as well as keyboard
shortcut symbols. Translation-only pull requests are welcome.

For work outside Xcode, use **Product → Export Localizations…** to produce
XLIFF, then **Product → Import Localizations…** when the translation is ready.
XLIFF is the easiest way to send a language to a translator without exposing
the source code.

## Add a language

1. In the project editor, add the language under **Info → Localizations**.
2. Add its identifier and native name to `AppLanguage` in
   `mac/zshell/AppLocalization.swift`. Resource selection and menu refresh share
   the identifiers from this enum.
3. Add that language to all three String Catalogs and translate every entry,
   including plural variants, the privacy prompt, and Finder Services.
4. Extend `mac/tests/test_app_localization.py` with the language, a regional
   preference, and representative runtime translations.
5. Run the app in that language and check menus, settings, the sidebars,
   dialogs, and `zshell +themes`.
6. Add the language and identifier to the table above.

## Add localizable text in Swift

Use AppKit for new UI. Localize a control's displayed string at its call site:

```swift
let button = NSButton(title: String(localized: "Create New Branch…"),
                      target: self, action: #selector(createBranch))
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
count-dependent grammar in a plural variant in `Localizable.xcstrings`. Display
user content, file names, terminal output, and other non-language data directly
so it is not treated as a lookup key:

```swift
let pathLabel = NSTextField(labelWithString: file.path)
```

The build has string extraction enabled. After adding source text, build once,
then translate the new entry in `Localizable.xcstrings` in all 16 non-English
languages. Existing SwiftUI literal extraction remains supported for legacy UI.

## Test a localization

In Xcode, choose **Product → Scheme → Edit Scheme… → Run → Options**, then set
**App Language** and **App Region**. Test all 17 languages, including long menu
labels and Arabic text. Also use the in-app picker to switch between all 18
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

Run `python3 mac/tests/test_app_localization.py` for full catalog coverage,
placeholder preservation, plural forms, and compiled resource checks. The same
probe exercises all 17 languages, regional aliases, persisted selection, system
fallback, interpolation, and Vim search without restarting. It uses a temporary
app and a unique preferences domain and removes both after the test. Build and
interactively test the app as well; the probe does not validate UI layout or a
running terminal's state.
