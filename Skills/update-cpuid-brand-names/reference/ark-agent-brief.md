# The brief for an ARK agent

One agent per batch from `gaps.py`, run in parallel. Replace `<N>` and
`<DIR>`. The brief is the whole of what the agent knows: keep the rules in it.

---

Collect Intel S-SPEC codes with their stepping from Intel ARK, for a list of
Intel processor models. This is data extraction: record only what Intel's page
says, never fill in from memory.

Input: `<DIR>/batch<N>.txt` — one model name per line (e.g. "Intel Core
i5-8265U", "Intel Xeon D-1529", "Intel Celeron J3455").

For each model:

1. Find its Intel product page
   (`intel.com/content/www/us/en/products/sku/<id>/<slug>/...`). ARK's own
   search does not work (it redirects to a 404). Use WebSearch (e.g.
   `"<model>" site:intel.com specifications`) to find the SKU URL. Load
   WebSearch/WebFetch with ToolSearch first if they are deferred. curl to
   intel.com is refused (403); WebFetch works.
2. WebFetch the page's ordering tab: replace the trailing `specifications.html`
   (or whatever page) with `ordering.html`, e.g.
   `https://www.intel.com/content/www/us/en/products/sku/88193/intel-core-i56200u-processor-3m-cache-up-to-2-80-ghz/ordering.html`.
   Ask WebFetch to quote verbatim every Spec Code (S-Spec) with its Ordering
   Code and Stepping.
3. Make sure the page is for exactly that model (i5-8265U is not i5-8365U;
   E3-1270 v5 is not v6; a suffix like F/T/E/K matters). If not, find the
   right SKU. A search result's slug can name another model while the title is
   right: load the page by its SKU id and check the title.

Write `<DIR>/batch<N>.json`, a JSON array, one object per input model, in
input order:

```json
{"model": "<as given>", "url": "<ordering page URL or null>",
 "specs": [{"sSpec": "SRxxx", "stepping": "V0", "orderingCode": "..."}],
 "note": "<only if something was off: not found, page for another model, stepping missing, ...>"}
```

A spec whose stepping the page does not show gets `"stepping": null`. A model
you cannot find gets `"specs": []` and a note. Some pages (several Atom P59xx)
have no ordering tab — `ordering.html` redirects to the specifications page:
record `"specs": []`, `"url": null` and say so. Do not guess an S-SPEC or a
stepping.

Return a short summary: how many models found, how many with specs, and any
problems.
