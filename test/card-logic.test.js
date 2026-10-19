/* SAMARRA 牌型引擎单元测试（Node 内置 test runner） */
const { test } = require("node:test");
const assert = require("node:assert");
const { classify, beats, shuffleDeal } = require("./card-engine");

test("单张", () => {
  assert.deepStrictEqual(classify([5]), { ok: true, type: "single", value: 5, len: 1 });
});
test("对子", () => {
  assert.deepStrictEqual(classify([9, 9]), { ok: true, type: "pair", value: 9, len: 2 });
});
test("三张", () => {
  assert.deepStrictEqual(classify([11, 11, 11]), { ok: true, type: "triple", value: 11, len: 3 });
});
test("王炸", () => {
  assert.deepStrictEqual(classify([16, 17]), { ok: true, type: "rocket", value: 99, len: 2 });
});
test("炸弹", () => {
  assert.deepStrictEqual(classify([7, 7, 7, 7]), { ok: true, type: "bomb", value: 7, len: 4 });
});
test("三带一", () => {
  assert.deepStrictEqual(classify([8, 8, 8, 4]), { ok: true, type: "triple_single", value: 8, len: 4 });
});
test("三带二", () => {
  assert.deepStrictEqual(classify([8, 8, 8, 4, 4]), { ok: true, type: "triple_pair", value: 8, len: 5 });
});
test("顺子 5 张", () => {
  assert.deepStrictEqual(classify([3, 4, 5, 6, 7]), { ok: true, type: "straight", value: 7, len: 5 });
});
test("顺子 12 张上限", () => {
  const c = [3,4,5,6,7,8,9,10,11,12,13,14];
  assert.deepStrictEqual(classify(c), { ok: true, type: "straight", value: 14, len: 12 });
});
test("含 2 不是顺子", () => {
  assert.strictEqual(classify([3,4,5,6,15]).ok, false);
});
test("含王不是顺子", () => {
  assert.strictEqual(classify([3,4,5,6,16]).ok, false);
});
test("连对 3 组", () => {
  assert.deepStrictEqual(classify([3,3,4,4,5,5]), { ok: true, type: "straight_pair", value: 5, len: 6 });
});
test("连对 4 组", () => {
  assert.deepStrictEqual(classify([8,8,9,9,10,10,11,11]), { ok: true, type: "straight_pair", value: 11, len: 8 });
});
test("飞机不带翼", () => {
  assert.deepStrictEqual(classify([6,6,6,7,7,7]), { ok: true, type: "airplane", value: 7, len: 6 });
});
test("飞机带单翼", () => {
  assert.deepStrictEqual(classify([6,6,6,7,7,7,3,5]), { ok: true, type: "airplane_single", value: 7, len: 8 });
});
test("四带两单", () => {
  assert.deepStrictEqual(classify([10,10,10,10,2,5]), { ok: true, type: "four_two", value: 10, len: 6 });
});
test("四带两对", () => {
  assert.deepStrictEqual(classify([10,10,10,10,3,3,5,5]), { ok: true, type: "four_two_pair", value: 10, len: 8 });
});
test("乱序输入也识别", () => {
  assert.deepStrictEqual(classify([4,8,8,8]), { ok: true, type: "triple_single", value: 8, len: 4 });
});
test("非法组合", () => {
  assert.strictEqual(classify([3,5,8]).ok, false);
  assert.strictEqual(classify([3,3,5,5,7,7,9]).ok, false);
  assert.strictEqual(classify([3,4,4,5,6,7]).ok, false);
});
test("两副牌同值 4 张炸弹", () => {
  assert.deepStrictEqual(classify([13,13,13,13]), { ok: true, type: "bomb", value: 13, len: 4 });
});
test("两副牌 4 张同值不能当顺子元素", () => {
  assert.strictEqual(classify([13,13,13,13,14]).ok, false);
});

/* beats 压牌比较 */
test("同型大压小", () => {
  assert.strictEqual(beats({ type: "single", value: 8, len: 1 }, { type: "single", value: 9, len: 1 }), true);
  assert.strictEqual(beats({ type: "single", value: 8, len: 1 }, { type: "single", value: 7, len: 1 }), false);
});
test("不同长度同型不可压", () => {
  assert.strictEqual(beats({ type: "straight", value: 8, len: 5 }, { type: "straight", value: 9, len: 6 }), false);
});
test("炸弹压非炸弹", () => {
  assert.strictEqual(beats({ type: "single", value: 15, len: 1 }, { type: "bomb", value: 3, len: 4 }), true);
});
test("炸弹同级比大小", () => {
  assert.strictEqual(beats({ type: "bomb", value: 7, len: 4 }, { type: "bomb", value: 8, len: 4 }), true);
  assert.strictEqual(beats({ type: "bomb", value: 7, len: 4 }, { type: "bomb", value: 6, len: 4 }), false);
});
test("王炸压一切", () => {
  assert.strictEqual(beats({ type: "bomb", value: 17, len: 4 }, { type: "rocket", value: 99, len: 2 }), true);
  assert.strictEqual(beats({ type: "rocket", value: 99, len: 2 }, { type: "rocket", value: 99, len: 2 }), false);
});
test("不同牌型不可互压", () => {
  assert.strictEqual(beats({ type: "pair", value: 3, len: 2 }, { type: "triple", value: 3, len: 3 }), false);
});
test("自由出牌（无上一手）", () => {
  assert.strictEqual(beats(null, { type: "single", value: 3, len: 1 }), true);
});

/* 洗牌发牌 */
test("三人一副：54 张，17×3+3 底牌", () => {
  for (let t = 0; t < 20; t++) {
    const { hands, base } = shuffleDeal(3);
    assert.strictEqual(Object.keys(hands).length, 3);
    assert.strictEqual(hands[0].length, 17);
    assert.strictEqual(hands[1].length, 17);
    assert.strictEqual(hands[2].length, 17);
    assert.strictEqual(base.length, 3);
    const all = [...hands[0], ...hands[1], ...hands[2], ...base];
    assert.strictEqual(all.length, 54);
    const set = new Set(all);
    assert.strictEqual(set.size, 15); // 3..17 共 15 种值
    assert.ok(hands[0].every((v, i) => i === 0 || hands[0][i] >= hands[0][i - 1]), "手牌已排序");
  }
});
test("四人两副：108 张，25×4+8 底牌", () => {
  for (let t = 0; t < 10; t++) {
    const { hands, base } = shuffleDeal(4);
    const counts = {};
    [...hands[0], ...hands[1], ...hands[2], ...hands[3], ...base].forEach(v => counts[v] = (counts[v] || 0) + 1);
    // 3..15 每值 8 张（两副 ×4 花色）；王每值 2 张
    for (let v = 3; v <= 15; v++) assert.strictEqual(counts[v], 8);
    assert.strictEqual(counts[16], 2);
    assert.strictEqual(counts[17], 2);
    assert.strictEqual(base.length, 8);
  }
});
test("二人模式：20×2+4 底牌", () => {
  const { hands, base } = shuffleDeal(2);
  assert.strictEqual(hands[0].length, 20);
  assert.strictEqual(hands[1].length, 20);
  assert.strictEqual(base.length, 4);
});
