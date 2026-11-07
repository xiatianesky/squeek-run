# SQUEEK SILO

A merge game built on how Squeekchain actually works, not on top of it.

Two Squeeks of the same level side by side become one a level higher and the
donor is burned — the same rule the SqueekNFT contract uses. Stack two level-6
Squeeks and the pair commits a **BLOCK**. With every block, the scam muck
pushed into the silo by the real hamster's work gets shoved back.

While you play, the hamster's real block progress floods muck up from the
floor, and every block that actually settles on Squeekchain clears the silo.
When the hamster stops, nothing saves you.

## How the live chain is used

The game is not a dashboard and it does not merely display the API. Three real
signals drive play:

| Signal | Source | What it does |
| --- | --- | --- |
| `builder.anchor.settledThroughRound` | `/v1/status` | `seed = round + 1`. Everyone in the same round gets the same piece sequence, so scores are comparable. |
| `builder.anchor.blockProgress` | `/v1/status` | The block bar: how close the real hamster is to finishing the next block. |
| a rise in `settledThroughRound` | `/v1/status` | A **settlement wave** — every real block that settles during your run clears the muck and pays a bonus. |

Polling is one request every 5 s, sending the endpoint's `ETag` back as
`If-None-Match`, so unchanged content comes back as a bare `304`. `roundDuration`
is read from `/v1/core` once a minute and is used to judge how stale a round is.

If the API is unreachable twice in a row the game switches to a clearly
labelled **SIM** mode that keeps playing but **cannot submit to the leaderboard**.
Fake live values are never shown.

## Why the score can be trusted

`engine.js` is a deterministic simulation: fixed 60 Hz ticks, a seeded PRNG,
no `Math.random`, no wall clock. A run is fully described by

```
(seed, [tick, action] log, final tick)
```

The Cloudflare Worker imports the **same file**, replays the submitted log, and
stores the score it computed itself. A tampered score is rejected with the
recomputed value. It also refuses rounds that are not current, and rejects logs
whose seed does not match the round.

```
POST /api/score        {round, seed, score, blocks, waves, ticks, events}
                       events = "tick:code,tick:code,..."  0=left 1=right 2=soft 3=hard 4=wave
GET  /api/leaderboard?round=N
GET  /api/round
```

## How to play

- `←` `→` move the falling Squeek between the six columns
- `↓` soft drop, `SPACE` hard drop, `P` pause
- touch: tap the left or right half to move, swipe down to drop

Every finished run produces a **run card** you can download — same seed, same
pieces, so the run replays exactly. Cards are game collectibles: **not NFTs,
not tokens, nothing is minted, nothing is bought.**

The original endless runner lives at `/classic/` and keeps working unchanged.

## Deploy

The static game is plain files — GitHub Pages serves the repo root.

The leaderboard is a Cloudflare Worker:

```
cd worker
npx wrangler kv namespace create LEADERBOARD     # paste the id into wrangler.toml
npx wrangler deploy
```

Then set the Worker URL in `index.html`:

```js
var LEADERBOARD_API = 'https://squeek-silo.<your-subdomain>.workers.dev';
```

(or add `<meta name="squeek-silo-api" content="...">`). With it empty the game
still plays and simply does not submit scores.

## Files

- `index.html` — the game: rendering, input, live layer, run cards
- `engine.js` — deterministic core, shared by the browser and the Worker
- `worker/` — leaderboard, server-side replay validation, KV storage
- `classic/index.html` — the original SQUEEK RUN runner

## Credit

Fan game for Squeekchain. Hamster art in the style of @squeekchain's pixel
hamster. Not official.

squeekchain-project: a418a29c-2c89-414e-834a-e4f7b45d2698
