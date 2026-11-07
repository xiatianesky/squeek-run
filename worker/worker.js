/**
 * SQUEEK SILO leaderboard Worker.
 *
 * The whole point: a submitted score is not trusted. The worker re-runs the
 * run from (seed, input log) with the exact same deterministic engine the
 * browser used, and only stores the score it recomputed itself.
 */
import "../engine.js";
import { keccak256, encodeAbiParameters, getAddress } from "viem";
import { privateKeyToAccount } from "viem/accounts";

const E = globalThis.SqueekEngine;

const MAX_EVENTS = 20000;
const MAX_TICKS = 216000;        // one hour of game time
const MAX_ROUND_DRIFT = 1;       // accept the round we are in, plus one either side
const MAX_PER_MINUTE = 6;
const TOP_N = 50;
const STATUS_URL = "https://api.squeekchain.com/v1/status";

// The badge contract. The worker signs (chainId, contract, player, round, score,
// blocks, squeekId) with EIP-191 so the contract can prove a mint came from a
// replayed run. squeekId is the official Squeek the player names for the badge
// trait; 0 means none. It is signed too, so the trait cannot be swapped after
// the fact. This must stay byte-identical to SqueekSiloBadge.digestFor.
const DEFAULT_CHAIN_ID = 11155111; // Sepolia, the Squeekchain deployment target
const RPC_URL = "https://ethereum-sepolia-rpc.publicnode.com";
const SQUEEK_NFT_SEL = "0x8178031e"; // SQUEEK_NFT(), only the Squeekchain build has it

function digestFor(chainId, contract, player, round, score, blocks, squeekId) {
  return keccak256(
    encodeAbiParameters(
      [
        { type: "uint256" },
        { type: "address" },
        { type: "address" },
        { type: "uint32" },
        { type: "uint32" },
        { type: "uint16" },
        { type: "uint32" }
      ],
      [
        BigInt(chainId),
        getAddress(contract),
        getAddress(player),
        round,
        score,
        blocks,
        squeekId
      ]
    )
  );
}

// v2 binds the badged Squeek; v1 did not have that parameter. The deployed
// bytecode decides which one to sign, so the worker and the contract can never
// drift during a redeploy.
async function digestForRun(env, contract, player, round, score, blocks, squeekId) {
  const chainId = Number(env.CHAIN_ID || DEFAULT_CHAIN_ID);
  const v2 = await isSqueekAware(env, contract);
  if (v2 === null) return { digest: null, abi: null };
  const digest = v2
    ? digestFor(chainId, contract, player, round, score, blocks, squeekId)
    : digestForV1(chainId, contract, player, round, score, blocks);
  return { digest: digest, abi: v2 ? "v2" : "v1" };
}

var versionCache = { address: "", v2: null, at: 0 };

async function isSqueekAware(env, contract) {
  var now = Date.now();
  if (versionCache.address === contract && now - versionCache.at < 600000) return versionCache.v2;
  var v2 = null;
  try {
    var r = await fetch(env.RPC_URL || RPC_URL, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "eth_call",
        params: [{ to: contract, data: SQUEEK_NFT_SEL }, "latest"]
      })
    });
    var j = await r.json();
    if (typeof j.result === "string" && j.result.length >= 66) {
      // The Squeek-aware build answers with the collection address.
      v2 = !/^0+$/.test(j.result.slice(2, 66));
    } else if (j.error) {
      // Older bytecode has no SQUEEK_NFT() at all, so the call reverts.
      v2 = false;
    }
  } catch (e) {
    v2 = null;
  }
  versionCache = { address: contract, v2: v2, at: now };
  return v2;
}

function digestForV1(chainId, contract, player, round, score, blocks) {
  return keccak256(
    encodeAbiParameters(
      [
        { type: "uint256" },
        { type: "address" },
        { type: "address" },
        { type: "uint32" },
        { type: "uint32" },
        { type: "uint16" }
      ],
      [BigInt(chainId), getAddress(contract), getAddress(player), round, score, blocks]
    )
  );
}

async function signRun(env, player, round, score, blocks, squeekId) {
  if (!env.SIGNER_PRIVATE_KEY) return null;
  if (!env.CONTRACT_ADDRESS) return null;
  if (/^0x0{40}$/i.test(env.CONTRACT_ADDRESS)) return null; // not deployed yet
  if (typeof player !== "string" || !/^0x[0-9a-fA-F]{40}$/.test(player)) return null;
  try {
    const chainId = Number(env.CHAIN_ID || DEFAULT_CHAIN_ID);
    const account = privateKeyToAccount(env.SIGNER_PRIVATE_KEY);
    const run = await digestForRun(
      env,
      env.CONTRACT_ADDRESS,
      player,
      round,
      score,
      blocks,
      squeekId
    );
    if (!run.digest) return null;
    const sig = await account.signMessage({ message: { raw: run.digest } });
    return {
      sig,
      signer: account.address,
      chainId,
      contract: getAddress(env.CONTRACT_ADDRESS),
      abi: run.abi
    };
  } catch (e) {
    return null;
  }
}

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
  "Access-Control-Max-Age": "86400"
};

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", ...CORS }
  });
}

// The official Squeek NFT ids run 1..9999. 0 means "no Squeek named".
function readSqueekId(raw) {
  if (raw == null || raw === "") return 0;
  var id = parseInt(raw, 10);
  if (!Number.isFinite(id) || id < 0 || id > 9999) return null;
  return id;
}

function cleanName(raw) {
  if (typeof raw !== "string") return "anon";
  var n = raw.replace(/[^A-Za-z0-9 _.-]/g, "").trim().slice(0, 16);
  return n || "anon";
}

function parseEvents(str) {
  if (typeof str !== "string" || !str.length) return null;
  var parts = str.split(",");
  if (parts.length > MAX_EVENTS) return null;
  var out = [];
  var prev = 0;
  for (var i = 0; i < parts.length; i++) {
    var kv = parts[i].split(":");
    if (kv.length !== 2) return null;
    var t = parseInt(kv[0], 10);
    var c = parseInt(kv[1], 10);
    if (!isFinite(t) || !isFinite(c)) return null;
    if (t < prev || t < 0 || t > MAX_TICKS) return null;
    if (c < 0 || c > 4) return null;
    prev = t;
    out.push([t, c]);
  }
  return out;
}

async function currentRound() {
  var ctl = new AbortController();
  var to = setTimeout(function () { ctl.abort(); }, 6000);
  try {
    var r = await fetch(STATUS_URL, { signal: ctl.signal, cf: { cacheTtl: 1 } });
    clearTimeout(to);
    if (!r.ok) return null;
    var d = await r.json();
    var a = (d && d.builder && d.builder.anchor) || {};
    if (a.settledThroughRound == null) return null;
    return { round: parseInt(a.settledThroughRound, 10), block: a.blockHeight != null ? parseInt(a.blockHeight, 10) : null };
  } catch (e) {
    clearTimeout(to);
    return null;
  }
}

async function rateLimited(env, ip) {
  var minute = Math.floor(Date.now() / 60000);
  var key = "rl:" + ip + ":" + minute;
  var cur = parseInt((await env.LEADERBOARD.get(key)) || "0", 10);
  if (cur >= MAX_PER_MINUTE) return true;
  await env.LEADERBOARD.put(key, String(cur + 1), { expirationTtl: 120 });
  return false;
}

async function handleScore(req, env) {
  var ip = req.headers.get("CF-Connecting-IP") || "unknown";
  if (await rateLimited(env, ip)) return json({ error: "rate_limited" }, 429);

  var body;
  try { body = await req.json(); } catch (e) { return json({ error: "bad_json" }, 400); }
  if (!body || typeof body !== "object") return json({ error: "bad_body" }, 400);

  var round = parseInt(body.round, 10);
  var seed = parseInt(body.seed, 10);
  var score = parseInt(body.score, 10);
  var blocks = parseInt(body.blocks, 10);
  var waves = parseInt(body.waves, 10);
  var ticks = parseInt(body.ticks, 10);

  if (![round, seed, score, blocks, waves, ticks].every(Number.isFinite)) return json({ error: "bad_fields" }, 400);
  if (score < 0 || blocks < 0 || blocks > 5000 || waves < 0 || waves > 5000) return json({ error: "bad_fields" }, 400);
  if (ticks > MAX_TICKS) return json({ error: "bad_ticks" }, 400);
  if (ticks < 30) return json({ error: "run_too_short" }, 400);
  if (seed !== round) return json({ error: "seed_mismatch" }, 400);

  var chain = await currentRound();
  if (!chain) return json({ error: "chain_unavailable" }, 503);
  if (Math.abs(round - (chain.round + 1)) > MAX_ROUND_DRIFT) return json({ error: "stale_round", round: chain.round + 1 }, 400);

  var events = parseEvents(body.events);
  if (!events) return json({ error: "bad_events" }, 400);

  // The one check that matters: rebuild the run ourselves.
  var st = E.replay(seed, events, ticks);
  if (!st) return json({ error: "bad_events" }, 400);
  if (st.score !== score || st.blocks !== blocks) {
    return json({ error: "score_mismatch", recomputed: { score: st.score, blocks: st.blocks } }, 400);
  }

  var key = "r:" + round;
  var list = [];
  try { list = JSON.parse((await env.LEADERBOARD.get(key)) || "[]") || []; } catch (e) { list = []; }
  if (!Array.isArray(list)) list = [];

  var entry = {
    name: cleanName(body.name),
    score: st.score,
    blocks: st.blocks,
    waves: Math.min(waves, 5000),
    at: Date.now()
  };
  list.push(entry);
  list.sort(function (a, b) { return b.score - a.score || a.at - b.at; });
  list = list.slice(0, TOP_N);
  await env.LEADERBOARD.put(key, JSON.stringify(list), { expirationTtl: 60 * 60 * 24 * 30 });

  var rank = list.findIndex(function (e) { return e === entry; }) + 1;

  // A verified run can be minted as a badge, if the owner configured a signer.
  var badge = null;
  var squeekId = readSqueekId(body.squeekId);
  if (squeekId === null) return json({ error: "bad_squeek_id" }, 400);
  if (typeof body.player === "string") {
    var signed = await signRun(env, body.player, round, st.score, st.blocks, squeekId);
    if (signed) badge = signed;
  }

  return json({
    ok: true,
    rank: rank || list.length,
    score: st.score,
    round: round,
    badge: badge
  });
}

// A verified run, authorised to mint. Same replay check as /api/score, but it
// does not touch the leaderboard — used when a player connects a wallet after
// the run is already over.
async function handleBadge(req, env) {
  var ip = req.headers.get("CF-Connecting-IP") || "unknown";
  if (await rateLimited(env, ip)) return json({ error: "rate_limited" }, 429);

  var body;
  try { body = await req.json(); } catch (e) { return json({ error: "bad_json" }, 400); }
  if (!body || typeof body !== "object") return json({ error: "bad_body" }, 400);

  var round = parseInt(body.round, 10);
  var seed = parseInt(body.seed, 10);
  var score = parseInt(body.score, 10);
  var blocks = parseInt(body.blocks, 10);
  var ticks = parseInt(body.ticks, 10);
  if (![round, seed, score, blocks, ticks].every(Number.isFinite)) return json({ error: "bad_fields" }, 400);
  if (seed !== round) return json({ error: "seed_mismatch" }, 400);

  var chain = await currentRound();
  if (!chain) return json({ error: "chain_unavailable" }, 503);
  if (Math.abs(round - (chain.round + 1)) > MAX_ROUND_DRIFT) return json({ error: "stale_round", round: chain.round + 1 }, 400);

  var events = parseEvents(body.events);
  if (!events) return json({ error: "bad_events" }, 400);

  var st = E.replay(seed, events, ticks);
  if (!st) return json({ error: "bad_events" }, 400);
  if (st.score !== score || st.blocks !== blocks) {
    return json({ error: "score_mismatch", recomputed: { score: st.score, blocks: st.blocks } }, 400);
  }

  var squeekId = readSqueekId(body.squeekId);
  if (squeekId === null) return json({ error: "bad_squeek_id" }, 400);

  var signed = await signRun(env, body.player, round, st.score, st.blocks, squeekId);
  if (!signed) return json({ error: "badge_not_configured" }, 503);
  return json({
    ok: true,
    badge: signed,
    score: st.score,
    blocks: st.blocks,
    squeekId: signed.abi === "v2" ? squeekId : 0
  });
}

async function handleLeaderboard(url, env) {
  var round = parseInt(url.searchParams.get("round") || "0", 10);
  if (!Number.isFinite(round) || round <= 0) return json({ error: "bad_round" }, 400);
  var list = [];
  try { list = JSON.parse((await env.LEADERBOARD.get("r:" + round)) || "[]") || []; } catch (e) { list = []; }
  return json({
    round: round,
    scores: (Array.isArray(list) ? list : []).slice(0, 20).map(function (e) {
      return { name: e.name, score: e.score, blocks: e.blocks, waves: e.waves };
    })
  });
}

export default {
  async fetch(req, env) {
    var url = new URL(req.url);
    if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });

    try {
      if (url.pathname === "/api/score" && req.method === "POST") return await handleScore(req, env);
      if (url.pathname === "/api/badge" && req.method === "POST") return await handleBadge(req, env);
      if (url.pathname === "/api/leaderboard") return await handleLeaderboard(url, env);
      if (url.pathname === "/api/round") {
        var c = await currentRound();
        if (!c) return json({ error: "chain_unavailable" }, 503);
        return json({ round: c.round + 1, settledThroughRound: c.round, block: c.block });
      }
      if (url.pathname === "/" || url.pathname === "/health") return json({ ok: true, service: "squeek-silo" });
    } catch (e) {
      return json({ error: "worker_error", detail: String(e && e.message || e) }, 500);
    }
    return json({ error: "not_found" }, 404);
  }
};
