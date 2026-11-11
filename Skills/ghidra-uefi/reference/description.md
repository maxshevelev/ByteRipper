# The module description

A review leaves three things behind: the program (names, types, signatures,
comments), the artifact the app draws from it, and the **module
description**: one Markdown document that says what the module is for, how
it works and how it is built. The C answers *what does this function do*;
the description answers *what is this module, and where in it do I look*.
It is an article for one reader: a service-centre technician who does not
program and does not know how the code is implemented. It gives them an idea of
what the module is for, the logic of its work, how it works with other modules
and how it is built inside, without deep technical detail.

It is not the review's record. How far the review has got is in the app and in
the store (`code_query`), per function; what the next agent needs goes in those
rows and in the report to the person. Nothing of the review's process belongs
here: no coverage, no revision history, no list of what is left to do.

The description is a result of the review, not a summary written at the end.
It is started on the first pass, corrected as the review learns, and true to
the code at every publish.

## Where it lives

- In the module's Ghidra project, in the program's `ByteRipper` options, so
  it is saved and kept with the review (`Owner.java`, `Harvest.java`).
- Written with `ghidra_describe` under the write lease, and read back with
  `ghidra_description` (`text`, `sections`, `bytes`).
- Published with the review: the publish snapshots it, stores it in the CAS
  as an object of its own (`text/markdown`, UTF-8) and names it in the
  reading — `reading.description` in the manifest and `description` in the
  module's review history (`reference/cas.md`). A change to the description
  alone makes the next revision; an unchanged one is the same revision.
- Shown by the app in the code panel, under **Description** beside ASM and C.

The owner normalises the text: LF line ends, no trailing blanks, one final
newline. Up to 256 KiB.

## Writing it

`ghidra_describe` takes the whole document, or one section: with `section`,
`text` replaces the body of that `## ` heading (without the heading) — the
section is added at the end if it is missing. Empty `text` is refused; `delete: true`
removes a section, or the whole description. `before` or `after` names the section
this one goes beside: a new section is placed there, and either alone moves an
existing one. `ghidra_description` reads one `section`, or with `outline: true` only
the headings and the size, so a section is changed without carrying the rest.
With `section`, `old_text` and `new_text` change one string inside it, and are
refused unless `old_text` occurs there exactly once.
Write the outline once, then work section by section; read it with
`ghidra_description` before changing a section someone else may have
touched.

- **Start early.** After the first look at the entry point and the strings:
  the title, the summary, `What it is` and a first `What it does`. Say what is a
  first guess in words.
- **Keep it true.** When a function's role is understood, a guess is confirmed
  or refuted, the section that says it is updated before the next publish. A
  description that says something the review has since disproved is a defect of
  the review.
- **Finish it.** Before `ghidra_done`: every section that has something to say
  says it, in the plain words below.

## The structure

The headings are fixed, in this order, in English, written exactly so. A section
with nothing to say yet is left out rather than left empty. `###` subsections
are free.

**The module's own bytes, not the firmware around it.** A description is keyed
by the module's SHA-256, so it shows in every firmware that holds the same
bytes, on other boards too. It states as facts only what follows from those
bytes: what its functions do, defects in its code, values folded in at build
time (PCDs), and branches that cannot run because of those values. What
depends on the surrounding image — a file present or absent, which modules hold
a GUID or install a PPI, who calls it, NVRAM contents, the APRIORI order,
another module's size, a guess at the boot order — is written as a condition,
not as a finding: "if no firmware volume holds file X (GUID …), the update is
dropped silently", not "on this board the update fails". "Cannot happen" is
written only when the reason is in the module's own code. The one place that
names the firmware the review was made in is the reference line in
`What it is`.

```markdown
# <ModuleName>

<Summary: what the module is and what it is for, in a few plain sentences.>

## What it is
## What it does
## Execution flow
## Interactions
## Inside the module
## Failures
## Known problems
## Terms
```

### `# <ModuleName>` and the summary

The module's name as the firmware file names it. The paragraph under it is what
someone reads who reads nothing else: three to five sentences.

### `## What it is`

As short as it can be: two to four short bullets, each one a detail that
matters for this module.

- **Origin**, in one line: whose code it is (EDK2, AMI, Insyde, AMD, Intel,
  the OEM), the source path when there is one, how closely the build matches
  it, and how sure that is.
- **What is unusual**, only if something is: a dependency the source does not
  declare (the dependency expression is in the firmware file, not in the hashed
  image, so it is "this build's file"), an unusual dispatch, build-time settings
  that change the behaviour.
- **Exactly one reference line**: `Reviewed in: <machine>, board <board>`. It
  says in which firmware the review was made, not where the module is: the
  same bytes in another firmware show the same description.

No general explanation of what a PEIM, a DXE driver or the PEI stage is, no
flash addresses or volume ranges, no dump file name, no repeat of the summary.
An abbreviation that needs explaining goes to `Terms`.

### `## What it does`

What the module does for the machine, what it gives the rest of the firmware and
what goes wrong without it.

### `## Execution flow`

The main chains of execution and the reactions to events, in plain language.

- The chains, as short ordered walks: start-up, screens, the decision, boot
  attempts, the fallback order, scans, updates. A branch that changes the outcome
  — waking from sleep, a missing device — is told as such.
- A short list of the events the module registers for, when each fires and what
  the module does on it: ready-to-boot, the exit-boot-services hand-over, virtual
  address change, protocol notifications, timers, key events.
- Each chain and each event links the main function or functions responsible for
  it, as `[Name](0xADDRESS)` or `` `Name` ``: usually one or two, not an inventory,
  with helpers left out. A sentence must still be understood without following
  the link.

### `## Interactions`

The other modules and the parts of the machine it works with: what it needs from
them, what it gives them, and the settings it reads or keeps, each said by what
it is for. Not a table of GUIDs.

### `## Inside the module`

How it is built: its main parts and what each is responsible for, the information
it keeps. A part is named by what it does. Not an inventory of functions, and the
code the module merely links in is one sentence together.

### `## Failures`

What shows at the bench: a POST or halt code, a message, a beep, a hang, a reset,
a device that goes missing. For each: when it happens, what it means, and where
to look next, as far as the code shows. The number or the exact message belongs
here: it is what the technician reads off the bench.

### `## Known problems`

Defects and oddities the review found, in plain language, each with its practical
effect: what could go wrong on a real machine, and when. Each is also in a note
at its place in the code and in the report to the person.

### `## Terms`

Only the narrow terms specific to this module's review that the article actually
uses, each explained in full: what the thing is, where it sits and why it matters
to this module. Common terms a technician already knows (BIOS, USB, CMOS, UEFI,
Variable) stay out: they clutter the content. A module with no such terms has no
`Terms` section.

## The Markdown

CommonMark with GitHub's tables, as Foundation reads it:

- headings `#`, `##`, `###`; paragraphs; `-` and `1.` lists, nested by
  indentation; tables; fenced code blocks; `>` quotes;
- `` `code` ``, `**bold**`, `*italic*`, `~~struck~~`, `[text](target)`.

No HTML, no images, no footnotes.

### Links into the code

- `[ProcessFv](0x9DFD3F8)` — a function, by its entry address as Ghidra
  holds it. The app opens it in the code; Back returns to the description.
- `` `ProcessFv` `` — a function's name written as code is a link too, while
  the module has a function of that name; so is `` `0x9DFD3F8` `` while the
  code holds that address.
- `[text](https://…)` opens in the browser. Any other target is shown as
  text.

A link is optional, except in `Execution flow`, where the main functions are
linked: it helps the reader who wants the code, and a sentence must be understood
without following it.

## Tone

- More text than symbols. Plain prose in simple, clear language, not a play of
  abbreviations, technical names and addresses.
- Every abbreviation is expanded in parentheses at its first mention in the text,
  shortly: "DXE (Driver Execution Environment)". `Terms` does not repeat every
  abbreviation: it explains only the narrow terms of this module.
- A routine is referred to by what it does, not by its address, and a technical
  name only where the reader needs it. `Execution flow` also carries links to the
  main functions; that is not a function inventory.
- No band tables, no function inventories with addresses, no decompiler artefacts
  (`FUN_`, `local_`, `HASH:`), no revision history, no review status.
- Facts from the code. A conclusion drawn from a pattern says so, and a guess is
  never written as a fact; what is not understood is said where it matters to the
  reader.
- English, like the names and comments in the code.
- Typically one to five screens: a small module needs a paragraph per section, a
  large one subsections.
