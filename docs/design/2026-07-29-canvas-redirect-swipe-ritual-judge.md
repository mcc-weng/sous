> Paste this into the live Claude Design conversation (the one already running the M3
> pass) before it designs the ritual/week-board screens. Everything else already
> established there — tone, persona, locked constraints, tokens/components — stands;
> this adds new screens, it does not remove anything already planned.

## Update to the brief: a new swipe-based ritual alternative, plus a judge moment on verdicts

**Important: please still design the current ritual/week-board flow exactly as
originally briefed** — free-text guided Q&A, the "開始本週儀式" button on Week Board.
That's real, shipped functionality and needs a finished design regardless of what
happens next. What follows is *additional* scope, not a replacement: we're exploring a
swipe-based alternative to that same ritual moment, and it isn't decided yet which one
ships first — so both need to exist as real, complete designs, not one placeholder and
one real screen. Two new full-screen surfaces join Cook Mode as the app's non-sheet,
full-immersion screens:

**Explore Deck** — an always-on, ambient swipe surface reachable from a prominent peek
card on the Kitchen Counter home screen (alongside the existing hero card/chip row —
you have the layout call there). Swipe right = like, left = pass, up = opens a small
text field on the card for a "yes, but" note (e.g. "沒有蝦"). Zero commitment, no plan
impact — this is browsing for fun and signal, not a task.

**Ritual Swipe Session** — launched from a CTA button in a chat message (小當家
announcing the ritual in character) or from the Week Board's existing "開始本週儀式"
button. Same three-gesture mechanic, but every right/up swipe assigns a dish to a day,
building the week live — want a visible sense of progress (e.g. "3 of 5 filled"), not
just a raw card stack. Ends in a lock/confirm moment equivalent to today's 鎖定! —
treat this as an emotional high point worth real attention, similar tier to the 上菜
cook-completion celebration. A swipe-up note doesn't resolve instantly — the modified
card may reappear a few cards later once 小當家 has an answer; give that re-entry some
subtle distinct treatment (e.g. a small "updated" tag).

**Judge/competition framing on the verdict moment** — this is where the Culinary Class
Wars / MasterChef tone should land hardest. The existing 4-tier rating (神作/不錯/普通/
翻車) stays as the only score — no new numeric scale. What's new: the optional
finished-dish photo (already planned for Cook Mode) now also feeds a short chef
"commentary" line, generated from the rating + how the cook session went + history with
that dish. Frame this as 小當家 judging the plate, with drama drawn from comparing this
attempt to the user's *own* past attempts of the same recipe ("第三次做,比上次快了
十分鐘") — no opponent, no leaderboard, that's intentionally out of scope for now.

**Please don't design**: multiplayer/social comparison (another household's dish),
demographic-based recommendation, or a separate "themed challenge" mode — all
explicitly parked, not part of this pass.

Full mechanics/data-model spec if useful for structural grounding:
`docs/superpowers/specs/2026-07-29-swipe-ritual-judge-design.md` in the repo.
