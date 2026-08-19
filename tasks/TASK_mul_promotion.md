# Task: Decide whether `mul` (and/or `best`) guesses belong in the link graph

Open question, not yet actionable: `wp_convert` produces two fallback streams
that resolve link targets no per-language title matched. Neither feeds
`{lang}_links_converted.txt`, so neither can become a `wp_links` edge. Should
either be promoted?

**Do not promote on volume alone.** See "What is still missing" — the number
that would justify promotion has not been measured yet.

## Context

`wp_convert` resolves a link target in this order (spec §2.5): same-language
title, redirect, Commons, cross-language prefix, then the two fallbacks —

- `{lang}_mul_guesses.txt` — Wikidata's language-neutral `mul` label, where
  exactly one entity claims that name.
- `{lang}_mul_ambiguous.txt` — a `mul` hit on a name claimed by several
  entities. `load_qid_dict` keeps the first QID seen and records the collision.
- `{lang}_best_guesses.txt` — the `best` label, tried only on what `mul` missed.

## Decisions (fixed)

Treat as constraints; ask before deviating.

1. **`mul` is kept and flagged, never silently resolved.** Colliding keys are
   recorded and their hits segregated, rather than dropping them or letting a
   later duplicate relabel an entity.
2. **Ambiguous hits are never promoted**, whatever the audit says about the
   unambiguous ones. Which QID they resolve to is an artifact of dump order —
   `load_qid_dict` keeps the first seen — so promoting them would mint edges
   from an implementation detail. Their only legitimate use is inspection.
3. **`mul` is tried ahead of `best`**, so `best` sees only what `mul` missed
   and the two volumes read directly as `mul`'s incremental value.
4. **`best` scans `LANG_ORDER`, not label-chain order.** The chain is
   alphabetical by language code, so `best` was previously whichever edition
   sorted earliest rather than a deliberate choice.

### Why `mul` is not simply authoritative

The durable reason is the *kind* of identifier, not Wikidata's curation
quality — which is good and improving, as per-language labels are consolidated
into `mul`.

A page title is unique within a wiki because MediaWiki enforces it, so
title → QID is one-to-one and the primary conversion path is exact. A `mul`
value is a **name**, and names are many-to-one: "H", "Groningen", "Limburg" are
each claimed by several entities. No amount of upstream curation changes that,
because it is not an error being fixed — it is two entities legitimately
sharing a name.

This is also why the ambiguity rate must be measured hit-weighted, not
label-weighted: ambiguous names are disproportionately common words, so they
attract far more links than their share of the label set suggests.

## Evidence to date (run of 2026-08-13, 337 editions)

| stream | lines | notes |
|---|---|---|
| `links_converted` | 1,890,315,533 | the graph; unaffected by either fallback |
| `mul_guesses` | 35,743,705 | unambiguous |
| `mul_ambiguous` | 7,033,542 | **16.4%** of all 42.8 M `mul` hits |
| `best_guesses` | 59,657,405 | was 69,236,522 before `mul` was tried first |
| `conv_failed` | 178,365,487 | was 211,091,838 |

`mul` landed 42.8 M hits: ~9.6 M taken from `best` (which fell by exactly that)
and ~33 M that previously resolved to nothing (`conv_failed` fell by 32.7 M).

Label-level ambiguity across 19,329,513 distinct `mul` labels: 472,177 shared
by more than one entity (**2.44%**). Note the gap between that and the 16.4%
hit-weighted figure — this is the trap. An earlier estimate from a
QID-ordered dump sample suggested 0.4%, understating the real label-level rate
by 6x and the rate that actually matters by 40x. **Sample randomly.**

## What is still missing (this is what gates the decision)

Volume is known. **Precision is not.** Nobody has checked whether an
unambiguous `mul` hit is usually the *right* edge.

1. **Precision audit.** Take a random sample of `mul_guesses` hits, stratified
   across large and small editions, and hand-verify whether the resolved QID is
   what the link meant. Report a rate with an interval, not an anecdote.
2. **Redundancy against `wd_links`.** How many promoted edges would Wikidata
   already assert? Those add no discovery value to the WP-not-WD query (spec
   §5.1) even when correct, so headline volume overstates the gain.
3. **`mul` vs `best` disagreement.** On targets both could resolve, how often
   do they disagree, and who is right when they do? Disagreements are the
   cheapest available signal about each one's reliability.
4. **Effect on `wp_count`.** Promotion inflates witness counts. Since
   `wp_count` drives both discovery and anomaly detection, check whether it
   shifts the ranking of high-`wp_count` edges or only adds a long tail.

## Promotion criteria

Promote only if all hold:

- Precision on the random sample is high enough to sit alongside exact title
  matches without measurably polluting the graph — decide the threshold
  *before* looking, and record it.
- A meaningful share of promoted edges are absent from `wd_links` (else the
  gain is cosmetic).
- `wp_count` distortion is understood and acceptable.
- Ambiguous hits stay excluded regardless (decision 2).

If promoted, `wp_aggregate` must keep promoted edges distinguishable from exact
matches — a witness set cannot silently mix "this wiki linked these titles" with
"a name matched". Prefer a separate provenance marker over merging the streams.

## Open question: retire `best`?

`mul` is what `best` was improvising: a language-neutral canonical name, now
curated upstream instead of guessed from whichever sitelink happened to sort
first. `best` still lands 59.7 M hits after `mul` takes its share, so it is not
worthless — but nobody has checked whether those are *good*. Decide alongside
the audit above; the same precision question applies. Note `best` is also the
label column of `items.csv` and so of `wd_entities`, which is a separate
concern from its fallback role and would outlive its retirement as a fallback.

## Non-goals

- Changing the primary conversion path (§2.5 a–g).
- Changing how `mul` collisions are detected or stored.
- Re-running the pipeline solely to gather this evidence — the streams accrue
  on every run; audit them after the next rebuild happens for another reason.
