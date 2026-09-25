# Localization: the language the app speaks, and how it stays true

> English, Russian and German. The Mac's language by default, the user's own
> choice when they want one. And a way to tell — mechanically — when new
> functionality has shipped without help, or a translation has fallen behind
> the English it was made from.

## Who it is for

A **service-centre technician**. That decides the register, and it is the same
rule in both languages:

- **A settled national equivalent wins.** Where the trade has its own word, use
  it: `прошивка`, `дамп`, `материнская плата`, `Prüfsumme`, `Platine`.
- **Otherwise keep the English term.** Nobody at a bench says "таблица
  разделов флеш-памяти"; they say `$FPT`. Format names, structure names and
  acronyms — `$FPT`, `$CPD`, `MFS`, `BPDT`, `Boot Guard`, `FIT`, `SVN` — are
  the same in every language, because that is what the datasheets, the forums
  and the other tools call them. Translating them makes the help *harder* to
  use.
- **Explain the term, do not replace it.** The glossary's job is to say what
  `ARB SVN` is in the reader's language, not to invent a name for it.
- **The trade's word, not the dictionary's.** «Смещение» is what a dictionary
  gives for *offset*; «адрес» is what a bench says. «Рез» is a loan
  translation; «разрез» is Russian. «Куски» is colloquial where the app means
  a defined unit — «сегменты». Each of those was a correction from the bench,
  and each is the kind this rule exists to catch.

## The key is the English text

```swift
titleLabel.stringValue = L("Drop files here")
alert.messageText = L("Close “%1$@”?", name)
```

A site is localized by wrapping the literal it already had. There is no key to
invent and none to get wrong, and a string nobody has translated yet falls back
to **correct English** rather than to `settings.language.caption`.

- **`Packages/Localization`** holds the lookup and one catalogue per language:
  `Resources/<lang>.lproj/Localizable.strings`. English ships no file — the
  keys are the English.
- **Placeholders are positional** — `%1$@`, `%2$@` — because a German or a
  Russian sentence puts the subject and the object where its own grammar wants
  them. `Localization.format` substitutes them; it takes whatever the call site
  used to interpolate, because interpolation is what it replaces.
- **One English word, two words elsewhere**: `L("Edit", context: "menu")` looks
  up `menu|Edit`. Russian's Edit *menu* is «Правка» and its Edit *button* is
  «Изменить»; without the context they fight over one entry.
- **A key must never carry a live interpolation.** `L("at \(offset)")` is a
  different string on every call, so no translation can ever match it. It
  compiles, which is why the coverage script checks for it.

### What is deliberately not translated

- **`Packages/MEFirmware`'s diagnostics.** The engine is a faithful port of
  upstream MEAnalyzer and `Skills/sync-mea-engine` compares its messages with
  upstream's. Translating them would fight that skill on every sync. They are
  engine output, and they stay in upstream's English.
- **Format and structure names**, per the rule above.

## Which language, and the user's own choice

`LanguageChoice` is `.system` or `.fixed(…)`, stored under `AppLanguage` in the
app's defaults and resolved against `Locale.preferredLanguages`. A regional
name matches the plain language (`de-AT` is German); a language the app has not
been translated into falls back to English rather than to the Mac's next
choice.

**Settings ▸ Language** offers *Same as the Mac (…)* — which names what it
currently resolves to — and then each language **in itself**: Русский,
Deutsch. A reader hunting for their own language must not have to read another
one to find it.

**Changing it needs a relaunch, and the tab says so.** A menu bar, a window's
labels and a panel's columns are built when they are built; re-reading every
one of them at run time would be a second layout path through the whole app,
kept correct for ever, for a setting a user touches once. The tab offers
**Relaunch Now**.

The **help is the exception**: every page is rebuilt from the book when it is
shown, so it changes language immediately. That is worth having, because the
help is where a reader goes when the words are the problem.

Under test the language is pinned to English (`AppDefaults.startLocalization`).
The suite asserts on what the app *says*, and otherwise the same suite would
pass in Frankfurt and fail in Moscow.

## One phrase per control

A button can explain itself in two places — its tooltip and its accessibility
label — and they answer the same question. Set separately they drift, and they
had: twenty controls said it in both places, thirty-nine had only a tooltip,
thirty-four only an accessibility label, and the toolbar's Prev/Next Difference
buttons had **no tooltip at all** while every button beside them did.

So there is one door, `ControlHelp` in `HelpUI`:

```swift
ControlHelp.describe(button, L("Go to an offset or a bookmark"))
ControlHelp.describe(caseButton, name: L("Case Sensitive"),
                     tooltip: on ? L("…matching exactly") : L("…off, …"))
```

- **One phrase** where the name and the explanation are the same sentence.
- **`name:` + `tooltip:`** where they are not — a toggle, a toolbar item. The
  name is what the control *is* and what a screen reader says first; the
  tooltip is what it *does*. A screen reader must not have to read a whole
  sentence before every press, and a toggle's name must not flip with its
  state.
- **Not for labels.** A label's text is already what a screen reader reads;
  giving it a label as well makes it say the sentence twice. A label with a
  tooltip sets `toolTip` directly — the one exception, and deliberate.

`HeaderButton.make(symbol:describes:tooltip:…)` and the toolbar's
`makeCommandItem` both route through it, so a button cannot be built without
its words.

## Anchors: help that keeps up with the app

Functionality moves. Help does not move with it, and translations move last.
`Skills/help-coverage` is the repeatable way to find the three gaps that opens.

An **anchor** is a stable name for one piece of user-visible functionality,
declared on both sides:

```swift
// help: menu.file.append
add(L("Append File…"), #selector(MainViewController.appendFile), "")
```

```
@covers menu.file.append
```

The script joins the two sets:

- an anchor in the code that nothing covers is **functionality nobody wrote
  help for** — invisible otherwise, because the app ships and works;
- an anchor in the help that no code declares is **help for something that is
  gone**, which is worse than no help.

Each non-English help file also carries `@source-sha`, the fingerprint of the
English file it was translated from. When the English page changes, the
translation is reported **stale** — it is now describing an older app, which
is what makes localized help worse than none. `--bless` records a new
fingerprint, and is a statement that someone actually re-translated the page.

The script also compares the keys the code asks for with each language's
catalogue, and reports keys that carry a live interpolation.

```bash
python3 Skills/help-coverage/scripts/help_coverage.py
```

Anchor metadata never reaches the reader: `HelpTopicFile` reads `@covers` and
`@source-sha` out of the page, and a test asserts no reader ever meets them.

## Adding to it

- **A string**: wrap it in `L(…)`, then
  `help_coverage.py --emit-missing ru` prints it ready to translate.
- **A language**: add `Resources/<code>.lproj/Localizable.strings` and
  `Help/<code>/`, and add the case to `AppLanguage`. A file a language has not
  reached yet falls back to English, file by file, so a half-translated build
  is readable rather than blank.
- **A feature**: declare its anchor at the site that implements it, and
  `@covers` it from the page that explains it. That is not optional — see
  `CLAUDE.md`.
