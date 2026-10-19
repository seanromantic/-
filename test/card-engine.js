/* ============================================================================
 * SAMARRA 本地验证用牌型引擎（与 sql/schema.sql 中 RPC 逻辑等价）
 * 仅用于单元测试与本地 Mock 服务，不参与线上运行。
 * 牌值编码：3=3 ... 10=10, J=11, Q=12, K=13, A=14, 2=15, 小王=16, 大王=17
 * ========================================================================== */

function classify(cards) {
  const n = cards.length;
  if (!n) return { ok: false, err: "empty" };
  const sorted = [...cards].sort((a, b) => a - b);
  const cnt = {};
  sorted.forEach(v => cnt[v] = (cnt[v] || 0) + 1);
  const uniq = Object.keys(cnt).map(Number).sort((a, b) => a - b);
  const k = uniq.length;
  const vMin = uniq[0], vMax = uniq[k - 1];
  const ok = (type, value) => ({ ok: true, type, value, len: n });

  if (n === 1) return ok("single", sorted[0]);
  if (n === 2 && sorted[0] === 16 && sorted[1] === 17) return ok("rocket", 99);
  if (n === 2 && k === 1) return ok("pair", vMax);
  if (n === 3 && k === 1) return ok("triple", vMax);

  if (n === 4) {
    if (k === 1) return ok("bomb", vMax);
    if (k === 2) {
      const t = uniq.find(v => cnt[v] === 3);
      if (t) return ok("triple_single", t);
    }
    return { ok: false, err: "invalid 4-cards" };
  }

  if (n === 5) {
    if (k === 2 && (cnt[vMin] === 3 || cnt[vMax] === 3)) {
      return ok("triple_pair", cnt[vMin] === 3 ? vMin : vMax);
    }
    if (k === 5 && vMax <= 14 && vMax - vMin === 4) return ok("straight", vMax);
    return { ok: false, err: "invalid 5-cards" };
  }

  if (n === 6) {
    const four = uniq.find(v => cnt[v] === 4);
    if (four) return ok("four_two", four);
    if (k === 3 && vMax <= 14 && vMax - vMin === 2 && uniq.every(v => cnt[v] === 2))
      return ok("straight_pair", vMax);
    if (k === 2 && vMax <= 14 && vMax - vMin === 1 && cnt[vMin] === 3 && cnt[vMax] === 3)
      return ok("airplane", vMax);
    return { ok: false, err: "invalid 6-cards" };
  }

  if (n === 8) {
    let four = 0, bad = false;
    uniq.forEach(v => { if (cnt[v] === 4) four = v; else if (cnt[v] !== 2) bad = true; });
    if (four && !bad && k === 3) return ok("four_two_pair", four);
    if (k === 4 && vMax <= 14 && vMax - vMin === 3 && uniq.every(v => cnt[v] === 2))
      return ok("straight_pair", vMax);
    for (let i = 0; i < k - 1; i++) {
      if (cnt[uniq[i]] === 3 && cnt[uniq[i + 1]] === 3 && uniq[i + 1] - uniq[i] === 1)
        return ok("airplane_single", uniq[i + 1]);
    }
    return { ok: false, err: "invalid 8-cards" };
  }

  // 顺子 5~12
  if (n >= 5 && n <= 12 && k === n && vMax <= 14 && vMax - vMin === n - 1)
    return ok("straight", vMax);

  // 连对 n/2 组
  if (n >= 6 && n % 2 === 0 && k === n / 2 && n / 2 >= 3 && vMax <= 14 && vMax - vMin === k - 1 &&
      uniq.every(v => cnt[v] === 2))
    return ok("straight_pair", vMax);

  // 飞机不带翼
  if (n >= 6 && n % 3 === 0 && k === n / 3 && k >= 2 && vMax <= 14 && vMax - vMin === k - 1 &&
      uniq.every(v => cnt[v] === 3))
    return ok("airplane", vMax);

  // 飞机带单翼
  if (n >= 8 && n % 4 === 0) {
    const g = n / 4;
    for (let i = 0; i + g - 1 < k; i++) {
      const run = uniq.slice(i, i + g);
      if (run[g - 1] <= 14 && run[g - 1] - run[0] === g - 1 && run.every(v => cnt[v] === 3))
        return ok("airplane_single", run[g - 1]);
    }
  }

  // 飞机带对翼
  if (n >= 10 && n % 5 === 0) {
    const g = n / 5;
    for (let i = 0; i + g - 1 < k; i++) {
      const run = uniq.slice(i, i + g);
      const wings = uniq.filter(v => v < run[0] || v > run[g - 1]);
      if (run[g - 1] <= 14 && run[g - 1] - run[0] === g - 1 && run.every(v => cnt[v] === 3) &&
          wings.every(v => cnt[v] === 2))
        return ok("airplane_pair", run[g - 1]);
    }
  }

  return { ok: false, err: "invalid combination" };
}

function beats(last, cur) {
  if (!last || !last.type) return true;
  if (cur.type === "rocket") return last.type !== "rocket";
  if (last.type === "rocket") return false;
  if (cur.type === "bomb") return last.type !== "bomb" || cur.value > last.value;
  if (last.type === "bomb") return false;
  if (cur.type === last.type && cur.len === last.len) return cur.value > last.value;
  return false;
}

/* 洗牌 + 发牌（与 SQL _shuffle_deal 一致） */
function shuffleDeal(maxPlayers) {
  const decks = maxPlayers === 4 ? 2 : 1;
  let deck = [];
  for (let d = 0; d < decks; d++) {
    for (let v = 3; v <= 15; v++)
      for (let s = 0; s < 4; s++) deck.push(v);
    deck.push(16); // 小王
    deck.push(17); // 大王
  }
  // Fisher-Yates
  for (let i = deck.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [deck[i], deck[j]] = [deck[j], deck[i]];
  }
  const per = maxPlayers === 2 ? 20 : maxPlayers === 3 ? 17 : 25;
  const baseCnt = maxPlayers === 2 ? 4 : maxPlayers === 3 ? 3 : 8;
  const hands = {};
  let idx = 0;
  for (let s = 0; s < maxPlayers; s++) {
    hands[s] = deck.slice(idx, idx + per).sort((a, b) => a - b);
    idx += per;
  }
  const base = deck.slice(idx, idx + baseCnt).sort((a, b) => a - b);
  return { hands, base };
}

module.exports = { classify, beats, shuffleDeal };
