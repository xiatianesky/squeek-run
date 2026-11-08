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
pieces, so the run replays exactly. A card is a picture, not a token: the only
thing this game mints is the optional badge described further down, and it
costs nothing but gas.

The original endless runner lives at `/classic/` and keeps working unchanged.

## Building on Squeekchain, the way the docs say to

Squeekchain is permissionless: there is no registry to join and no separate
chain to deploy to. The official integrations are read-only — `verifyGraph()`
in the quickstart ends with "Everything is read-only; nothing is signed or
sent" — so that is what this project does.

| Official contract | Read | Used for |
| --- | --- | --- |
| `SqueekCore.state()` | `settledThroughRound`, `blockHeight` | the round a run belongs to, and the completed Squeek block height stamped into a badge |
| `SqueekCore.configuration()` | `genesisTimestamp`, `roundDuration` | the current round, derived as `floor((t - genesis) / duration) + 1` |
| `SqueekNFT.ownerOf/level` | ownership + merge level | a badge can carry the player's own Squeek and its real level |

Addresses come from the Deployments table (release `core-sepolia-20261103`,
revision 7, Sepolia `11155111`):

- SqueekCore `0xFD6C166D4B8E2962E65746a13e5a0797CD4dE0c4`
- SqueekNFT `0xC4C7982657f00509548F3a3a41db7FA439a6856B`

`SqueekSiloBadge.mint()` calls `state()` and `configuration()` before it mints,
so a badge cannot claim a round the chain has not reached, and it records the
official block height in the token. If the core read ever fails, minting still
works; the token just loses the stamp. Nothing in this repo writes to
Squeekchain.

Holder perks follow the docs' "holder experiences" pattern: connect a wallet,
and `GET /v1/accounts/{address}` lists the Squeeks you actually hold. You name
one of them when you mint, and the contract reads `ownerOf` and `level` on
chain — a token that is not yours is refused, and level 0 there means never
merged, i.e. Level 1. The named Squeek and its level ride on the badge as
traits. It is cosmetic on purpose — the board stays identical for everyone in a
round, so the leaderboard is not pay-to-win.

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

### The badge contract

`contract/SqueekSiloBadge.sol` is a 999-supply ERC-721 on Sepolia, live at
`0xf1a5404abd0676EBEe7b5b540236C3B76eF51565`. It imports OpenZeppelin v5.0.2
over https and compiles on 0.8.24+ **without** `viaIR`. Deploy it with the
signer address as the only constructor argument, then point both sides at it:

What it is: 999 badges, ever. One per run per address, five per address total,
free to mint (gas only). The art is generated on chain from the official 22x14
Squeek bitmap, and the token stores the round, score, blocks, tier and the
official block height it was stamped with.

What it is not: not an official Squeekchain product, not a claim on anything,
not a token with a market. This is a fan game and the badge says so in its
metadata. No `SQK` and no promise of value appears anywhere.

- `index.html`: `<meta name="squeek-silo-contract" content="0x...">`
- `worker/wrangler.toml`: `CONTRACT_ADDRESS = "0x..."`

The Worker signs `(chainId, contract, player, round, score, blocks, squeekId)`
with EIP-191 after replaying the run, and the contract only mints with that
signature — so a badge cannot be minted for a score nobody played. Redeploying
the contract changes the digest, so update `CONTRACT_ADDRESS` in the same pass
and `npx wrangler deploy` again.

The Worker detects which build it is talking to (`SQUEEK_NFT()` exists only in
the current one) and signs the matching digest, so a half-finished redeploy
cannot hand out an unusable signature. If it cannot tell, it refuses to sign
rather than guess.

Deployment needs ~26.04M gas: the constructor writes the 18 palette strings into
storage, and a limit below ~25.72M reverts with `contract creation code storage
out of gas` — which looks like a wallet failure but is not. Gas is charged on
what is used, so give it a 34M limit.

Two earlier Sepolia deployments are dead and must not be used:
`0xdf2242B83Fbb0Bb93D89d757e4A546Ef35FD0eD7` and
`0x9Fdc32B947e91CC90EAcC902F51ac9B51e79683d`. Both predate the `chainState()`
`live` fix, so they would stamp every badge with block 0. Neither ever minted
(`totalMinted` is 0 on both) and the Worker no longer signs for them — the
digest binds the contract address — so `mint()` reverts. They cannot be
removed: the contract has no `selfdestruct`, and since Cancun (EIP-6780) it
would not delete code anyway.

## Files

- `index.html` — the game: rendering, input, live layer, run cards
- `engine.js` — deterministic core, shared by the browser and the Worker
- `worker/` — leaderboard, server-side replay validation, KV storage
- `classic/index.html` — the original SQUEEK RUN runner

## Credit

Fan game for Squeekchain. Hamster art in the style of @squeekchain's pixel
hamster. Not official.

squeekchain-project: a418a29c-2c89-414e-834a-e4f7b45d2698
