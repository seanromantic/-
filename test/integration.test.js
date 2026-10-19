/* SAMARRA RPC 集成测试：直接调用本地 Mock（模拟 Supabase RPC 全流程） */
const { test } = require("node:test");
const assert = require("node:assert");

const BASE = "http://127.0.0.1:9090/rest/v1/rpc/";
async function rpc(fn, body = {}) {
  const r = await fetch(BASE + fn, {
    method: "POST",
    headers: { "Content-Type": "application/json", "Prefer": "return=representation" },
    body: JSON.stringify(body)
  });
  const t = await r.text();
  const j = t ? JSON.parse(t) : null;
  if (!r.ok) { const e = new Error((j && j.message) || r.status); e.code = r.status; throw e; }
  return j;
}

test("管理员鉴权", async () => {
  assert.strictEqual(await rpc("is_admin", { p_nickname: "admin" }), true);
  assert.strictEqual(await rpc("is_admin", { p_nickname: "路人甲" }), false);
});

test("创建房间 + 人数校验", async () => {
  const room = await rpc("create_room", { p_max_players: 3, p_nickname: "玩家A", p_level: 3 });
  assert.strictEqual(room.max_players, 3);
  assert.match(room.room_code, /^[A-Z0-9]{6}$/);
  assert.strictEqual(room.status, "waiting");
  assert.strictEqual(room.players.length, 1);
  assert.strictEqual(room.players[0].is_host, true);
  await assert.rejects(rpc("create_room", { p_max_players: 5, p_nickname: "X" }), /人数/);
});

test("完整斗地主流程（3人）", async () => {
  const room = await rpc("create_room", { p_max_players: 3, p_nickname: "甲", p_level: 5 });
  const code = room.room_code;
  await rpc("join_room", { p_room_code: code, p_nickname: "乙", p_level: 2 });
  await rpc("join_room", { p_room_code: code, p_nickname: "丙", p_level: 8 });

  /* 非房主不能开始 */
  await assert.rejects(rpc("start_game", { p_room_code: code, p_nickname: "乙" }), /房主/);
  /* 人数未满校验已过（已满3） */

  const started = await rpc("start_game", { p_room_code: code, p_nickname: "甲" });
  const st = started.game_state;
  assert.strictEqual(st.phase, "bid");
  assert.strictEqual(st.hands["0"].length, 17);
  assert.strictEqual(st.hands["1"].length, 17);
  assert.strictEqual(st.hands["2"].length, 17);
  assert.strictEqual(st.base.length, 3);

  /* 甲叫 1 分 */
  const r1 = await rpc("bid", { p_room_code: code, p_nickname: "甲", p_points: 1 });
  assert.strictEqual(r1.game_state.current_seat, 1);
  /* 乙叫 3 分 */
  const r2 = await rpc("bid", { p_room_code: code, p_nickname: "乙", p_points: 3 });
  assert.strictEqual(r2.game_state.current_seat, 2);
  /* 丙不叫 */
  const r3 = await rpc("bid", { p_room_code: code, p_nickname: "丙", p_points: 0 });
  assert.strictEqual(r3.game_state.phase, "playing");
  assert.strictEqual(r3.game_state.landlord, 1);       /* 乙 3 分最高 */
  assert.strictEqual(r3.game_state.multiplier, 3);
  assert.strictEqual(r3.game_state.hands["1"].length, 20); /* 地主拿底牌 */
  assert.strictEqual(r3.game_state.current_seat, 1);      /* 地主先出 */

  /* 没轮到甲时甲不能出牌 */
  await assert.rejects(rpc("play_cards", { p_room_code: code, p_nickname: "甲", p_cards: [r3.game_state.hands["0"][0]] }), /还没轮到/);
  /* 乙出最小单张 */
  const minV = Math.min(...r3.game_state.hands["1"]);
  const r4 = await rpc("play_cards", { p_room_code: code, p_nickname: "乙", p_cards: [minV] });
  assert.strictEqual(r4.game_state.current_seat, 2);
  assert.strictEqual(r4.game_state.last_play.seat, 1);
  /* 丙出更大的单张 */
  const hand2 = r4.game_state.hands["2"];
  const bigger = hand2.find(v => v > minV);
  const smaller = hand2.find(v => v < minV);
  /* 若没有更大则跳过（多数情况存在） */
  if (bigger) {
    const r5 = await rpc("play_cards", { p_room_code: code, p_nickname: "丙", p_cards: [bigger] });
    assert.strictEqual(r5.game_state.current_seat, 0);
    /* 甲“不要” */
    const r6 = await rpc("pass_turn", { p_room_code: code, p_nickname: "甲" });
    assert.strictEqual(r6.game_state.current_seat, 1);
    /* 乙也不要 → 轮到丙（自由出牌） */
    const r7 = await rpc("pass_turn", { p_room_code: code, p_nickname: "乙" });
    assert.strictEqual(r7.game_state.current_seat, 2);
    assert.strictEqual(r7.game_state.last_play, null);
    /* 丙出炸弹/任意（最小对子若有） */
    const cnt = {};
    r7.game_state.hands["2"].forEach(v => cnt[v] = (cnt[v] || 0) + 1);
    const pair = Object.keys(cnt).find(v => cnt[v] >= 2);
    if (pair) {
      const r8 = await rpc("play_cards", { p_room_code: code, p_nickname: "丙", p_cards: [Number(pair), Number(pair)] });
      assert.strictEqual(r8.game_state.last_play.type, "pair");
    }
  } else if (smaller) {
    /* 丙出更小的会被拒绝 */
    await assert.rejects(rpc("play_cards", { p_room_code: code, p_nickname: "丙", p_cards: [smaller] }), /管不上|超出/);
    /* 丙选择不要 */
    const r5 = await rpc("pass_turn", { p_room_code: code, p_nickname: "丙" });
    assert.strictEqual(r5.game_state.current_seat, 0);
  }
});

test("非法操作被拒绝", async () => {
  const room = await rpc("create_room", { p_max_players: 2, p_nickname: "丁", p_level: 1 });
  const code = room.room_code;
  await rpc("join_room", { p_room_code: code, p_nickname: "戊", p_level: 1 });
  const started = await rpc("start_game", { p_room_code: code, p_nickname: "丁" });
  /* 完成叫地主：丁叫 1 分 → 戊不叫 → 丁成地主，进入出牌 */
  await rpc("bid", { p_room_code: code, p_nickname: "丁", p_points: 1 });
  const st = (await rpc("bid", { p_room_code: code, p_nickname: "戊", p_points: 0 })).game_state;
  assert.strictEqual(st.phase, "playing");
  assert.strictEqual(st.landlord, 0);
  /* 出不在手牌中的牌 */
  await assert.rejects(rpc("play_cards", { p_room_code: code, p_nickname: "丁", p_cards: [999] }), /手牌/);
  /* 空牌 */
  await assert.rejects(rpc("play_cards", { p_room_code: code, p_nickname: "丁", p_cards: [] }), /请选择/);
  /* 出牌张数超出持有 */
  const v = st.hands["0"][0];
  await assert.rejects(rpc("play_cards", { p_room_code: code, p_nickname: "丁", p_cards: [v, v, v, v, v] }), /超出/);
});

test("四人两副牌开局", async () => {
  const room = await rpc("create_room", { p_max_players: 4, p_nickname: "A" });
  const code = room.room_code;
  await rpc("join_room", { p_room_code: code, p_nickname: "B" });
  await rpc("join_room", { p_room_code: code, p_nickname: "C" });
  await rpc("join_room", { p_room_code: code, p_nickname: "D" });
  const st = (await rpc("start_game", { p_room_code: code, p_nickname: "A" })).game_state;
  assert.strictEqual(st.hands["0"].length, 25);
  assert.strictEqual(st.hands["1"].length, 25);
  assert.strictEqual(st.hands["2"].length, 25);
  assert.strictEqual(st.hands["3"].length, 25);
  assert.strictEqual(st.base.length, 8);
});

test("文字冒险：读节点 / 存档 / 恢复", async () => {
  const stories = await rpc("list_stories", {});
  assert.ok(stories.length >= 1);
  const s = stories[0];
  const start = await rpc("get_story_node", { p_story_id: s.id, p_node_key: "start" });
  assert.strictEqual(start.node_key, "start");
  assert.ok(start.option_a && start.target_a);
  /* 存档绑定昵称 */
  const saved = await rpc("save_story_progress", { p_nickname: "存档玩家", p_story_id: s.id, p_node_key: start.target_a });
  assert.strictEqual(saved.current_node, start.target_a);
  const prog = await rpc("get_story_progress", { p_nickname: "存档玩家", p_story_id: s.id });
  assert.strictEqual(prog.current_node, start.target_a);
  /* 不存在节点报错 */
  await assert.rejects(rpc("save_story_progress", { p_nickname: "x", p_story_id: s.id, p_node_key: "nope" }), /不存在/);
});

test("故事编辑器 CRUD", async () => {
  const ns = await rpc("create_story", { p_title: "测试故事" });
  assert.ok(ns.id);
  let nodes = await rpc("get_story_nodes", { p_story_id: ns.id });
  assert.strictEqual(nodes.length, 1);
  assert.strictEqual(nodes[0].node_key, "start");
  const sv = await rpc("save_story_node", {
    p_story_id: ns.id, p_node_key: "node2", p_content: "第二个节点",
    p_option_a: "去甲", p_target_a: "start", p_option_b: null, p_target_b: null, p_pos_x: 100, p_pos_y: 200
  });
  assert.strictEqual(sv.ok, true);
  nodes = await rpc("get_story_nodes", { p_story_id: ns.id });
  assert.strictEqual(nodes.length, 2);
  const del = await rpc("delete_story_node", { p_story_id: ns.id, p_node_key: "node2" });
  assert.strictEqual(del.ok, true);
  nodes = await rpc("get_story_nodes", { p_story_id: ns.id });
  assert.strictEqual(nodes.length, 1);
});

test("退出房间与解散", async () => {
  const room = await rpc("create_room", { p_max_players: 2, p_nickname: "独行侠" });
  const code = room.room_code;
  await rpc("join_room", { p_room_code: code, p_nickname: "二号" });
  /* 二号离开 */
  let r = await rpc("leave_room", { p_room_code: code, p_nickname: "二号" });
  assert.strictEqual(r.players.length, 1);
  assert.strictEqual(r.players[0].is_host, true);
  /* 房主离开 → 房间销毁 */
  r = await rpc("leave_room", { p_room_code: code, p_nickname: "独行侠" });
  assert.strictEqual(r.destroyed, true);
  assert.strictEqual(await rpc("get_room", { p_room_code: code }), null);
});
