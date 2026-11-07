/*
 * SQUEEK SILO - deterministic simulation core.
 *
 * Loaded as a classic script in the browser (globalThis.SqueekEngine) and
 * imported by the Cloudflare Worker so a submitted run can be replayed and
 * its score recomputed server-side.
 *
 * A run is fully described by (seed, event log). No wall clock, no
 * Math.random: fixed 60 Hz ticks and a seeded PRNG only.
 */
(function (global) {
  'use strict';

  var COLS = 6;
  var ROWS = 12;
  var MAX_LEVEL = 6;
  var TICK = 1 / 60;
  var FALL = 5.0;          // rows per second
  var WATER_TICKS = 600;   // muck starts at one row every 10 s
  var MIN_WATER_TICKS = 150; // and tightens to one row every 2.5 s
  var BLOCK_CLEARS = 3;    // rows of muck a committed block pushes back

  var A_LEFT = 0, A_RIGHT = 1, A_DOWN = 2, A_DROP = 3, A_WAVE = 4;

  function mulberry32(a) {
    return function () {
      a |= 0; a = (a + 0x6D2B79F5) | 0;
      var t = Math.imul(a ^ (a >>> 15), 1 | a);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }

  function rollLevel(st) {
    var r = st.rng();
    if (r < 0.52) return 1;
    if (r < 0.82) return 2;
    if (r < 0.96) return 3;
    return 4;
  }

  function createGame(seed) {
    var st = {
      seed: seed >>> 0,
      cols: [],
      piece: null,
      nextLevel: 1,
      score: 0,      // verified: merges and block clears only
      wavePts: 0,    // live bonus, not part of the ranked score
      merges: 0,
      blocks: 0,
      waves: 0,
      drops: 0,
      water: 0,
      waterAt: 0,
      over: false,
      tick: 0,
      rng: mulberry32(seed >>> 0),
      pops: []
    };
    for (var c = 0; c < COLS; c++) st.cols.push([]);
    st.nextLevel = rollLevel(st);
    spawn(st);
    return st;
  }

  function spawn(st) {
    st.piece = { c: COLS >> 1, y: ROWS - 0.05, lv: st.nextLevel };
    st.nextLevel = rollLevel(st);
    st.pops.length = 0;
  }

  function landing(st, c) { return st.cols[c].length; }

  function canMove(st, dir) {
    if (!st.piece || st.over) return false;
    var nc = st.piece.c + dir;
    if (nc < 0 || nc >= COLS) return false;
    return st.cols[nc].length < ROWS;
  }

  function move(st, dir) { if (canMove(st, dir)) st.piece.c += dir; }

  function lock(st) {
    var p = st.piece;
    if (st.cols[p.c].length >= ROWS) { st.over = true; return; }
    st.cols[p.c].push(p.lv);
    st.drops++;
    st.piece = null;
    resolve(st);
    if (!st.over) spawn(st);
  }

  function softDrop(st) {
    if (!st.piece || st.over) return;
    st.piece.y -= 1;
    if (st.piece.y <= landing(st, st.piece.c)) { st.piece.y = landing(st, st.piece.c); lock(st); }
  }

  function hardDrop(st) {
    if (!st.piece || st.over) return;
    st.piece.y = landing(st, st.piece.c);
    lock(st);
  }

  function compact(col) {
    var out = [];
    for (var i = 0; i < col.length; i++) if (col[i] !== 0) out.push(col[i]);
    col.length = 0;
    for (var j = 0; j < out.length; j++) col.push(out[j]);
  }

  function at(st, c, i) {
    var col = st.cols[c];
    return (c >= 0 && c < COLS && i >= 0 && i < col.length) ? col[i] : 0;
  }

  // Pairwise merge, exactly like SqueekNFT: two adjacent identical levels
  // combine into one a level higher and the donor is burned.
  function findPair(st) {
    var c, i, col, v;
    for (i = 0; i < ROWS; i++) {
      for (c = 0; c < COLS; c++) {
        v = at(st, c, i);
        if (v <= 0) continue;
        if (at(st, c + 1, i) === v) return { c: c, i: i, c2: c + 1, i2: i, v: v };
        if (at(st, c, i + 1) === v) return { c: c, i: i, c2: c, i2: i + 1, v: v };
      }
    }
    return null;
  }

  function clearMuckRows(st, n) {
    for (var k = 0; k < n; k++) {
      if (st.water <= 0) return;
      st.water--;
      for (var c = 0; c < COLS; c++) {
        if (st.cols[c][0] === -1) st.cols[c].shift();
      }
    }
  }

  function checkOverflow(st) {
    for (var c = 0; c < COLS; c++) if (st.cols[c].length > ROWS) { st.over = true; return true; }
    return false;
  }

  function resolve(st) {
    var guard = 0, chain = 0;
    while (guard++ < 500) {
      var p = findPair(st);
      if (!p) break;
      chain++;
      var next = p.v + 1;
      st.cols[p.c][p.i] = 0;
      st.cols[p.c2][p.i2] = 0;
      if (next > MAX_LEVEL) {
        st.blocks++;
        st.score += 1000 + 250 * st.blocks;
        st.pops.push({ c: p.c, i: p.i, v: -2, t: 0, chain: chain });
        clearMuckRows(st, BLOCK_CLEARS);
      } else {
        st.cols[p.c][p.i] = next;
        st.merges++;
        st.score += 10 * next * next * chain;
        st.pops.push({ c: p.c, i: p.i, v: next, t: 0, chain: chain });
      }
      for (var c = 0; c < COLS; c++) compact(st.cols[c]);
      if (checkOverflow(st)) return;
    }
  }

  function applyWave(st) {
    if (st.over) return;
    st.waves++;
    st.wavePts += 100 + 50 * st.waves;
    for (var c = 0; c < COLS; c++) {
      var col = st.cols[c], keep = [];
      for (var i = 0; i < col.length; i++) if (col[i] !== -1) keep.push(col[i]);
      col.length = 0;
      for (var j = 0; j < keep.length; j++) col.push(keep[j]);
    }
    st.water = 0;
    st.waterAt = st.tick;
  }

  function riseWater(st) {
    st.water++;
    for (var c = 0; c < COLS; c++) st.cols[c].unshift(-1);
    checkOverflow(st);
  }

  // The muck speeds up as the run goes on: 10 s per row at the start,
  // tightening to 2.5 s per row after ~150 s. Deterministic in game ticks,
  // so a replay reproduces it exactly.
  function waterInterval(tick) {
    var need = WATER_TICKS - Math.floor(tick / 20);
    return need < MIN_WATER_TICKS ? MIN_WATER_TICKS : need;
  }

  function step(st, dt) {
    if (st.over) return;
    st.tick++;
    if (st.tick - st.waterAt >= waterInterval(st.tick)) { st.waterAt = st.tick; riseWater(st); if (st.over) return; }
    if (st.piece) {
      st.piece.y -= FALL * dt;
      var land = landing(st, st.piece.c);
      if (st.piece.y <= land) { st.piece.y = land; lock(st); }
    }
    for (var i = 0; i < st.pops.length; i++) st.pops[i].t++;
  }

  function applyAction(st, code) {
    if (st.over) return;
    if (code === A_LEFT) move(st, -1);
    else if (code === A_RIGHT) move(st, 1);
    else if (code === A_DOWN) softDrop(st);
    else if (code === A_DROP) hardDrop(st);
    else if (code === A_WAVE) applyWave(st);
  }

  function replay(seed, events, finalTick) {
    var st = createGame(seed);
    var last = 0, k, t;
    for (k = 0; k < events.length; k++) {
      t = events[k][0] | 0;
      if (t < last) return null;
      if (t - last > 216000) return null;
      while (st.tick < t && !st.over) step(st, TICK);
      last = t;
      applyAction(st, events[k][1] | 0);
    }
    if (finalTick) { var ft = finalTick | 0; if (ft < last) return null; if (ft - last > 216000) return null; while (st.tick < ft && !st.over) step(st, TICK); }
    return st;
  }

  global.SqueekEngine = {
    COLS: COLS, ROWS: ROWS, MAX_LEVEL: MAX_LEVEL, TICK: TICK, WATER_TICKS: WATER_TICKS, MIN_WATER_TICKS: MIN_WATER_TICKS, waterInterval: waterInterval,
    A_LEFT: A_LEFT, A_RIGHT: A_RIGHT, A_DOWN: A_DOWN, A_DROP: A_DROP, A_WAVE: A_WAVE,
    createGame: createGame, step: step, move: move, softDrop: softDrop, hardDrop: hardDrop,
    applyWave: applyWave, applyAction: applyAction, replay: replay, landing: landing
  };
  if (typeof module !== "undefined" && module.exports) module.exports = global.SqueekEngine;
})(typeof globalThis !== "undefined" ? globalThis : this);

