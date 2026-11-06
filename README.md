# SQUEEK RUN

SQUEEK RUN is an endless runner starring Squeektoshi, the hamster behind Squeekchain.

You run and jump. Jump over SCAM blocks and wriggling worms, run under the birds bobbing overhead — jump into one and you're out — and collect blue blocks along the way. Every 500 metres, the run settles into a block worth 6,900 SQK. Day turns to night every 1,000 metres. Speed starts at 8.0 and rises by 0.5 every 250 metres, up to 13.0. One hit ends the run, so timing matters — your best score is saved locally.

This version is powered by Squeekchain's live API: it polls the official API every 5 seconds, and every real block that settles while you run counts as a round survived. The run only ends when you hit something, so the longer you stay alive, the more live rounds you survive.

Every 6,900 SQK earns a milestone card — one per run, for your highest level only. Each card has its own look, drawn from 999 combinations of fur colour, body shape, eyes and accessories. Download it as a picture and share it on X. The cards are game milestone cards, not on-chain NFTs.

The game is built around how Squeekchain works, so you learn it by playing: the hamster running is the work, the distance you cover is work adding up, and a block is what that work settles into. SCAM blocks are the things to avoid, just like in the real project.

Just open it in a browser and run.

## How to play

- Space / Up / Tap: jump (single jump)
- Jump over SCAM blocks and worms, collect blue blocks (+500 SQK)
- Birds fly overhead, bobbing up and down: run under them, don't jump into them
- Every 500m: a block is mined (+6,900 SQK)
- Speed: starts 8.0, +0.5 every 250m, capped at 13.0
- Day and night alternate every 1,000m
- Best score is saved in your browser

## Milestone cards

- Every 6,900 SQK: one milestone card, for the highest level reached in that run only
- 999 trait combinations: 9 fur colours, 3 body shapes, 3 eye styles, 6 accessories, 3 backgrounds
- Download the card as a PNG and share it on X from the game-over screen

## Run it

Open `index.html` in a browser, or host it statically. No install, no build step, no wallet, no transaction. The only external call is a read-only poll of the public Squeekchain API (`api.squeekchain.com/v1/status`).

## Credit

Fan game for Squeekchain. Hamster art in the style of @squeekchain's pixel hamster.

squeekchain-project: a418a29c-2c89-414e-834a-e4f7b45d2698
