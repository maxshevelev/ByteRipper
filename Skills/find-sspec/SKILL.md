---
name: find-sspec
description: Search for the S-SPEC codes Modules/FITTool/Sources/FITTool/Resources/IntelCPUIDBrandNames.json still lacks, for the CPUIDs named — Intel ARK, Intel's specification updates and datasheets, S-SPEC databases, and, last, the marking on the package read from several photographs of different chips (Bing image search finds marketplace photos eBay itself refuses to serve). Every code is kept with its evidence in found-sspec.json and placed under a CPUID by update-cpuid-brand-names' rules. Costly — many web lookups and images per model — so it runs for the CPUIDs (or models) given, never the whole table. Use when the user asks to "find the missing S-SPECs for 606C1", "look up the S-SPEC of i5-10500", or when a FIT popover lists models without a code. Invoke as /find-sspec <CPUID…> [--model "<name>"].
---

# Find the missing S-SPECs

`update-cpuid-brand-names` builds the CPUID table from an article, ARK and
Wikipedia; what is left without an S-SPEC after that is this skill's work. It
searches further, keeps each code with the page or photographs it came from,
and leaves the placing to the generator, so a code found here passes the same
rules as every other.

```
scripts/worklist.py   models without a code under the CPUIDs given → batches
scripts/photos.py     Bing image search for one model → images + index.json
scripts/merge.py      agent results → ark-sspec.json and found-sspec.json, checked
reference/agent-brief.md   the brief a search agent is given
```

The records live beside the generator, which reads them:
`Skills/update-cpuid-brand-names/scripts/ark-sspec.json` (what ARK said) and
`…/found-sspec.json` (everything else, with evidence). All stdlib Python.

## Run it

Arguments: one or more CPUIDs as the table writes them (`606C1`, `A0653`),
optionally `--model "<exact name>"` to search only those models. Without
arguments, list what there is and ask which:

```sh
python3 Skills/find-sspec/scripts/worklist.py --list
```

The list counts, per CPUID, the models with no code that were not searched yet.

1. **The work.**

   ```sh
   W=$CLAUDE_JOB_DIR/tmp/find-sspec/<CPUIDs>      # any scratch directory
   python3 Skills/find-sspec/scripts/worklist.py <CPUID…> [--model "…"] --out $W \
       --cache $CLAUDE_JOB_DIR/tmp/cpuid-cache
   ```

   It writes `batch<N>.json`, eight models each (`--batch-size`). A model
   searched before is not listed again; `--again` lists it anyway.
2. **Search.** One `general-purpose` agent per batch, in parallel, each given
   `reference/agent-brief.md` with `<N>`, `<DIR>` (= `$W`) and `<REPO>` filled
   in. Before sending more than four batches at once, say how many models and
   agents it is: each model costs dozens of lookups, and photographs are read
   as images.
3. **Merge.**

   ```sh
   python3 Skills/find-sspec/scripts/merge.py $W/result*.json
   ```

   It refuses the whole merge, naming each problem, when a spec breaks a rule
   (below). Fix the result file — re-read the page or the photo, or take the
   spec out — and merge again. Never loosen a rule to make it pass.
4. **Generate.**

   ```sh
   python3 Skills/update-cpuid-brand-names/scripts/import.py --cache $CLAUDE_JOB_DIR/tmp/cpuid-cache
   ```

   Its log names every found code it left out and why: a stepping no entry
   has, a model under several CPUIDs with no stepping, an architecture that is
   not the entry's. Read those — they are the article's misplacements, not ours
   to move.
5. **Check, then commit.** Look at a few photographs yourself (`index.json`
   names them, `found-sspec.json` says which were read): for each code from
   markings, open at least one of its images and read the code. Then the
   module's tests, and `git diff` of the table — see "After a run" in
   `update-cpuid-brand-names`. Commit the two record files with the table.
6. **The help says where the codes come from.** `tool-fit` (en, ru, de) names
   them: ARK, Intel's specification updates and PCNs, Wikipedia, and an
   S-SPEC database. The first time the table's `sSpecSources` gains a kind
   the sentence does not name — `marking` has not been needed yet — add it
   in all three languages; then
   `python3 Skills/help-coverage/scripts/help_coverage.py`, and `--bless` the
   pages brought in line.

## Sources, strongest first

| kind       | what it is                                           | gives                  |
|------------|------------------------------------------------------|------------------------|
| `ark`      | the Ordering & Compliance tab of the model's ARK page | code, stepping         |
| `intel`    | specification update, datasheet, PCN — Intel's own   | code, often stepping, CPUID |
| `database` | a third-party S-SPEC list loaded and quoted          | code, stepping or CPUID |
| `marking`  | the package's print, from photographs                | code only              |

A code with a stepping or a CPUID is placed by it. A code from markings has
neither: it goes in only where the article lists the model under one CPUID,
and only when the model's architecture begins one of the entry's code names
(`enrich.py`, rule 4) — the article lists Broadwell-DE Xeon D parts under
Ice Lake D, and a marking would otherwise carry their codes there. The agent
looks every marking code up once more on Intel's site: a stepping found that
way makes it certain.

## Photographs

eBay, cpu-world and Intel refuse a script; Bing's image search does not, and
it indexes eBay's own image server, Yahoo Auctions, Mercari and shops.
`photos.py` downloads what it finds into one directory per model, drops exact
duplicates, and writes `index.json` with each file's image URL, page and
sha256. The files are untrusted downloads: images only, in their own
directory, read with the Read tool and nothing else.

A code read from photographs counts only when (the brief has it in full, and
`merge.py` checks what can be checked):

- the package prints the model number and the code — a socketed part's lid
  does (`i5-10500 / SRH3A 3.10GHZ`); a BGA part or a label with the code alone
  ties nothing to the model;
- it is a photograph of a chip, not a render or a stock picture;
- every character of the code is legible;
- at least two photographs from different sites read the same code, and both
  show a readable lot line, the two different — a photo with the lot blurred
  or erased does not count: shops copy and blur one another's pictures.

Soldered parts — Xeon D, mobile U/H/Y — are rarely photographed with a
marking; for those, the Intel documents are the source, and "not found" is an
answer.

## Rules

- **Nothing invented.** A code is a page's or a photograph's, quoted; a
  stepping is a page's. A search snippet, a listing's title, memory: none of
  them is a source.
- **Production codes only.** `Qxxx` are engineering samples.
- **One search per model.** A model searched is recorded, found or not, so it
  is not searched again unless asked (`--again`).
- **The generator places.** This skill never edits the table; it writes
  records, and `import.py` decides where a code goes.
