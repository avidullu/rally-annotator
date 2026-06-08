# Ending reasons — what they mean & how to label them

The `ending_reason` column records **why the rally (point) ended**, judged from the
**last shot**. There are seven values, shared across all the net-separated racquet sports
this tool supports (badminton, tennis, table tennis, pickleball, padel):

```
unknown | winner | forced_error | unforced_error | service_fault | let | other
```

**`unknown` is the default** — the annotator resets the reason to `unknown` after every save, so a
rally you didn't classify is honestly recorded as `unknown` (never the previous rally's reason). Set a
specific reason when you can; `unknown` simply marks rallies still needing a verdict.

**One core principle:** every reason **except `winner`** (and the neutral `unknown`) is charged to the
player/side that **LOST** the rally. `winner` is the only one that credits the side that **won** it.

This guide is written for a human rater clicking through a match. Where a rule comes from
the laws of the sport it is marked **[rule]**; where it is an analytics *convention* (a
judgement call that charters agree to apply consistently) it is marked **[convention]**.

---

## The decision procedure (top to bottom — stop at the first match)

1. **Was the rally replayed under the rules, with no point scored?**
   (e.g. a tennis/padel serve that clips the net and lands in the correct box; a table-tennis
   serve that touches the net and is otherwise good; outside interference; receiver not ready.)
   → **`let`**. *A net-cord during open rally play that lands in is NOT a let — keep going.*

2. **Did the point end on the SERVE because of a server fault?**
   (serve into the net, serve outside the correct service court, illegal service action / foot
   fault, or a tennis/padel **double fault**.)
   → **`service_fault`**.

3. **Did the winning side's last shot land IN and go unreturned** — the opponent couldn't
   reach it, or only waved at it without meaningful contact? (A clean untouched serve / **ace**
   counts here.) → **`winner`**.

4. **Otherwise the rally ended on a MISS by the loser** (ball/shuttle **out**, **into the net**,
   or not legally returned). Now judge **pressure**:

   > **The pressure test:** Did the loser have **both enough time AND court position** to make a
   > routine return, given the opponent's *immediately preceding* shot (its placement, pace,
   > power, spin, depth, angle)? Ask: *"Would a typical competent player at this level be
   > expected to make that shot?"* **[convention]**

   - **Yes** — had time and position, missed a routine ball → **`unforced_error`**.
   - **No** — time or position was taken away; the miss was induced → **`forced_error`**.

5. **Can't judge it, or it ended off-court** (occluded footage, injury/retirement, code/point
   penalty, hindrance, equipment failure) → **`other`**. Use sparingly.

**Tie-breaker [convention]:** when you genuinely can't tell forced from unforced, **default to
`unforced_error`**. Only mark `forced_error` when you can *point to the specific pressure* (the
wide/fast/deep/spinny ball that removed the player's time or position). This keeps `forced_error`
a positively-evidenced label and stops it from inflating. The forced/unforced boundary is a real
*continuum* — charters disagree on borderline calls, so fix the default in writing for your team.

---

## The six reasons, defined

### `winner`
The point-ending shot landed **in** and the opponent did **not** make a meaningful return
(couldn't reach it, or only waved). Credit to the side that won the rally. A clean untouched
legal serve (an **ace**) is conventionally a `winner`, not a `service_fault`.
*Examples:* a smash that bounces untouched; a deceptive drop the opponent never reaches; a
passing shot down the line.
*Not a winner:* if the opponent reaches it but mishits **under pressure**, that is **their**
`forced_error`, not your `winner`.

### `forced_error`
A miss by the **loser** (out, into the net, or not legally returned) where the opponent's
previous shot applied enough pressure — placement, pace, power, spin, depth, angle — that the
player did **not** have time *and* position for a routine return. They were *made* to miss.
*Examples:* a wide, heavy serve return netted while lunging at full stretch; a hard smash dug up
but floated long because the player was off-balance and rushed.

### `unforced_error`
A miss by the **loser** on a shot they had **time AND position** to make routinely, with little
or no pressure. They gave it away.
*Examples:* a comfortable mid-court ball drilled into the net; a relaxed clear pushed past the
back line; a sitter smashed long.

### `service_fault`
A fault by the **server on the serve itself** that loses the point or the serve — judged against
the sport's *service* rules, not general rally play. Includes: serve into the net, serve out of
the correct service court/box, illegal service action (e.g. badminton contact above 1.15 m,
ITTF illegal toss, pickleball illegal motion), foot fault, and a tennis/padel **double fault**.
*Note:* a **first**-serve fault followed by a good second serve is **not** charged here — only the
serve that actually loses the point is. A clean ace is a `winner`, not a `service_fault`.

### `let`
A **replay** defined by the laws, where **nobody is charged** a point — the rally "didn't count":
a tennis/padel service net-cord that still lands in the correct box (replayed, unlimited times);
a table-tennis serve that touches the net and is otherwise correct; an outside interruption; the
receiver not ready. Use **only** when the rule says *replay*.
*Caution:* a net-cord during a **rally** (not the serve) that lands in is live — **not** a `let`.

### `other`
Catch-all for endings that fit none of the above: the outcome is genuinely unclear/occluded on
video; or the point ended administratively (injury retirement, code/point penalty, hindrance
call, equipment failure) rather than on a struck shot. Prefer a specific category whenever the
footage supports it.

---

## The cases people ask about most

These are the calls that trip raters up — resolved precisely.

### A. The ball/shuttle lands **OUT** (past the baseline or outside the sidelines)
This is **always the hitter's error** — the side that **lost** the rally. The opponent merely let
it sail (or it cleared the line untouched), so it is **never** the opponent's `winner`. Decide
`forced` vs `unforced` purely by **pressure on the hitter** at the moment they struck it — look at
the opponent's *previous* shot, not the out ball itself:
- Rushed, stretched, off-balance, or handling heavy pace/spin/depth → **`forced_error`**.
- Set and balanced, with time on a routine ball, and still sprayed it → **`unforced_error`**.

"Beyond the baseline" vs "outside the sideline" doesn't change the logic — both are *out*, both are
the hitter's miss. (In tennis and badminton the **line is in**; this applies only when it lands
fully outside.) **So "out" is not automatically `forced`** — that label needs visible pressure;
otherwise it's `unforced`.

### B. The ball/shuttle goes **INTO the net** (fails to cross)
Same as an "out" ball — it's the hitter's error, and the **pressure test** decides: `forced_error`
if they were rushed/stretched, `unforced_error` if they dumped a routine ball.
**Exception:** if the failure-to-cross happens **on the serve**, it is a **`service_fault`** (in
tennis/padel, a missed second serve = double fault), not a rally error — the rally never legally
began.

### C. The **net-cord / net tape** (ball or shuttle clips the top)
- **During a rally:** it is **live and good** in all of these sports. Play continues, so the rally
  ends on whatever happens **next**: if the opponent can't reach the dribbler → it's a `winner`
  (a "net-cord winner"); if they scramble and then miss → judge *that* miss as forced/unforced.
  A rally net-cord is **never** a `let`.
- **On the serve — sports differ:**
  | Sport | Serve clips the net and… |
  |---|---|
  | **Tennis / Padel** | …lands in the correct box → **`let`** (replay). Lands outside → `service_fault`. |
  | **Table tennis** (ITTF) | …is otherwise correct → **`let`** (serve replayed). |
  | **Badminton** (BWF) | …passes over and lands in the service court → **live, play on** (no service let). But a serve shuttle **caught/suspended on the net** is a **`service_fault`** (BWF Law 13.2), *not* a let. |
  | **Pickleball** (2026 USAP) | …lands in the correct court → **live, play on** (the old service-let was removed). Lands out → `service_fault`. |

---

## Sport-specific notes

- **Tennis (ITF):** double fault → `service_fault`; service net-cord into the box → `let`; lines
  are **in**; a clean ace → `winner`.
- **Badminton (BWF):** service contact must be with the whole shuttle below **1.15 m** from the
  court surface (Law 9.1.6; the older "above the waist" wording is the alternative trial law). A
  shuttle landing outside the lines or failing to pass the net is a fault; a **serve caught on the
  net is a fault** (`service_fault`), while a mid-rally suspended shuttle (Law 14.2.3, only *after*
  the serve is returned) is a `let`. Lines are **in**.
- **Table tennis (ITTF):** a serve touching the net assembly but otherwise correct is a **`let`**
  (replayed); in a rally, a ball that touches the net and still lands on the opponent's court is a
  **good return**.
- **Pickleball (USAP 2026):** **no** service let — a net-clip that lands in the correct court is
  live; illegal serve motion / net-clip-out → `service_fault`.
- **Padel (FIP):** like tennis for the serve net-cord `let`. Wall play means a rally ball off the
  glass after one bounce is still live. (One edge case — a let-bound serve that touches the net and
  then the side **wire mesh** before its 2nd bounce — is finicky; verify against current FIP text.)

---

## Consistency tips

- The forced/unforced split is a **judgement call on a continuum**. Pick the default
  (`unforced` when unsure) and apply it the same way every time — consistency matters more than
  any single borderline call.
- If you're building a rating *team* or a regression set, consider logging a confidence note on
  borderline forced/unforced calls so they can be audited or re-bucketed later.
- These six values are deliberately a small, shared vocabulary. Keep to them (don't invent new
  spellings) so downstream aggregation stays clean.

### Mapping to tennis charting codes (optional)
If you cross-reference the [Match Charting Project](https://github.com/JeffSackmann/tennis_MatchChartingProject):
`winner = *`, `forced_error = #`, `unforced_error = @` (with location tags `n` = net, `w` = wide,
`d` = deep, `x` = wide+deep). These are charting conventions layered on top of the official rules.

---

## Sources

- Match Charting Project — quick-start & codes: <https://www.tennisabstract.com/blog/2015/09/23/the-match-charting-project-quick-start-guide/>
- "The continuum of errors" (forced vs unforced is a continuum): <http://www.tennisabstract.com/blog/2017/01/13/the-continuum-of-errors/>
- Leo Levin's pressure definition of unforced error: <https://www.tennis.com/news/articles/what-is-an-unforced-error-a-meditation-on-the-tennis-player-s-least-favorite-stat>
- ITF Rules of Tennis: <https://www.itftennis.com/en/about-us/governance/rules-and-regulations/>
- BWF Laws of Badminton: <https://www.worldbadminton.com/rules/>
- ITTF Table Tennis rules (Law 2.7 / 2.9): <https://www.ittf.com/handbook/>
- USA Pickleball rulebook: <https://usapickleball.org/what-is-pickleball/official-rules/>
- FIP Rules of Padel: <https://www.padelfip.com/rules-of-padel/>
