# The brief for a search agent

One `general-purpose` agent per batch from `worklist.py`, run in parallel.
Replace `<N>`, `<DIR>` and `<REPO>`. The brief is the whole of what the agent
knows: keep the rules in it.

---

Find the Intel S-SPEC codes (`SRxxx`) of a few processor models, with
evidence for each. This is data collection for a reference table read on a
repair bench: a wrong code is worse than none. Record only what a page or a
photograph you have actually looked at shows — never fill in from memory, never
take a search snippet or a seller's title as a source.

Input: `<DIR>/batch<N>.json`, an array of

```json
{"model": "Intel Core i5-10500", "cpuid": "A0653", "codeNames": ["Comet Lake S"],
 "steppings": ["G1"], "otherCPUIDs": {"A0655": ["Q0"]}, "ark": "not asked"}
```

`steppings` are those of the CPUID the table lists the model under;
`otherCPUIDs` where else it lists it. A model can be sold under several codes
on different dies (an i5-10500 exists as G1 and as Q0): find all of them, and
for each its stepping where any source gives one.

Load WebSearch and WebFetch with ToolSearch first if they are deferred.
`intel.com`, `ark.intel.com`, `cpu-world.com` and `ebay.*` refuse curl (403);
WebFetch works for Intel and not for cpu-world or eBay.

## For each model, in this order

1. **Intel ARK** — only if `ark` is `"not asked"`. Find the product page with
   WebSearch (`"<model>" site:intel.com specifications`; ARK's own search is
   broken), check the title is exactly this model (a suffix F/K/T/E/H/U
   matters), and WebFetch its ordering tab: the URL with `specifications.html`
   replaced by `ordering.html`. Ask WebFetch to quote verbatim every Spec Code
   with its Ordering Code and Stepping. Some pages have no ordering tab
   (`ordering.html` redirects to `specifications.html`): say so in the note.
   This goes in the result's `ark`, not in `specs`.

   **ARK's ordering tab lists every code the SKU was sold under, on every
   stepping.** When it gives codes with their steppings, the model is done:
   go to the next one. Steps 2–4 are for a model ARK gives nothing for — no
   page, no ordering tab, no codes, or codes without a stepping — and for a
   model whose `ark` was asked before with no specs.
2. **Intel documents** — the processor's *Specification Update* or
   *Datasheet* (an "Identification Information" / "Processor Identification"
   table lists S-Spec, stepping, CPUID and model), or a *Product Change
   Notification*. Find them with WebSearch (`"<model>" "specification update"
   site:intel.com`, `"<model>" S-Spec stepping site:intel.com`); `cdrdv2.intel.com`
   PDFs are found the same way. When WebFetch returns the PDF's raw bytes
   rather than text, save them (curl, if the host allows it) under
   `<DIR>/pdf/` and extract the text with a scratch Swift script using PDFKit
   (`PDFDocument(url:)?.string`) kept in `$CLAUDE_JOB_DIR/tmp`; no
   `pdftotext` or `pypdf` is installed. Quote the row.
3. **S-SPEC databases** that give a code with its stepping or CPUID on a page
   you can load (WebFetch). Quote the row. A page you could not load is not a
   source, however it looked in the search results.
4. **Photographs of the package** — last, and mainly for socketed parts. Run

   ```sh
   python3 -I <REPO>/Skills/find-sspec/scripts/photos.py "<model>" --out <DIR>/photos/<model with spaces as _>
   ```

   and read the images it lists in `index.json` with the Read tool (they are
   files in that directory; do not open them any other way). Add searches of
   your own with `--query` if the first ones bring nothing (`'"i5-10500" SRH'`
   when you know the code family from a sibling model). A code from photographs
   counts only when:

   - the package itself prints the **model number and the code** — the
     marking reads `INTEL® CORE™ i5 / i5-10500 / SRH3A 3.10GHZ / X122J379 (e4)`:
     brand, model, S-SPEC (and clock), lot. A BGA package or a label that shows
     the code without the model ties nothing to the model;
   - it is a **photograph of a chip**, not a render or a marketing picture (no
     lot line, perfect lettering, Intel's logo artwork) and not a picture of a
     board or a box;
   - you can read **every character** of the code. If one could be 8 or B,
     0 or D, 5 or S, 1 or I, the photo does not count;
   - **at least two photographs agree** — of different chips, from
     different sites. Different chips means **two lot lines, both read, that
     differ**. A photo whose lot is blurred, cut off or erased does not count
     towards the two: shops copy one another's pictures and blur the lot (the
     same chip has turned up sharp on one shop and blurred on another — the
     small number printed on the substrate edge, `02838`, gave it away). The
     same lot on two sites is one chip.
     Read up to about fifteen images per model; stop when two good ones agree.
   - The same photographs read **another code** for the same model: record
     both, each with its own photographs — a model can have two.

   A photograph never gives a stepping or a CPUID. When you have a code from
   photographs, look it up once more at steps 1–3 (`"SRH3A" site:intel.com`
   finds the ordering page that lists it): a stepping found that way makes the
   code certain.

For each code, `architecture` is the code name a source gives the model —
`Comet Lake`, `Ice Lake`, `Broadwell` (Intel's page lists it as "Code Name";
write it without "Products formerly" and without a segment letter). The table
lists some models under the wrong generation (Xeon D-15xx, Broadwell-DE, under
Ice Lake D); give what the source says, not what the input says.

## Write `<DIR>/result<N>.json`

A JSON array, one object per input model, in input order:

```json
{"model": "<as given>",
 "ark": {"url": "<ordering page URL or null>",
         "specs": [{"sSpec": "SRH3A", "stepping": "G1", "orderingCode": "…"}],
         "note": "<only if something was off>"} ,
 "specs": [
   {"sSpec": "SRH3A", "stepping": "G1" , "cpuid": null, "architecture": "Comet Lake",
    "evidence": [
      {"kind": "intel", "url": "<page>", "quote": "<the row, verbatim>",
       "gives": ["sSpec", "stepping"]},
      {"kind": "photo", "url": "<page from index.json>", "image": "<image from index.json>",
       "sha256": "<from index.json>", "reads": "INTEL CORE i5 / i5-10500 / SRH3A 3.10GHZ / X122J379",
       "lot": "X122J379"}]}],
 "note": "<what was tried and failed, briefly>"}
```

- `ark` is `null` when the input said ARK was asked already.
- `specs` lists the codes found **outside** ARK, or ARK codes you also
  confirmed elsewhere; an ARK code with its stepping needs nothing more.
- `kind`: `intel` (an Intel page or PDF other than the ordering tab),
  `database` (a third-party S-SPEC list), `photo`.
- `gives` says what that page states: always `sSpec`, plus `stepping` or
  `cpuid` if it states them. `stepping` and `cpuid` in the spec may be set only
  from such a page; leave them `null` otherwise.
- `reads` is the whole marking as you read it, lines separated by ` / `;
  `lot` the lot line, or `null` if the photo shows none.
- Only production codes `SRxxx`. `Qxxx` are engineering samples, not sold
  models: leave them out.
- A model with nothing found: `"specs": []` and a note of what you tried.

Return a short summary: per model, the codes found and from which kind of
source, and anything doubtful.
