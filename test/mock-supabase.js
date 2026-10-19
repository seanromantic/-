/* ============================================================================
 * SAMARRA 本地 Mock Supabase 服务器（仅测试用）
 * 在无有效云凭据时，模拟 sql/schema.sql 中的全部 RPC 行为，
 * 供浏览器自动化做端到端验证。逻辑与 SQL 版保持一致。
 * 运行：node test/mock-supabase.js（默认 9090 端口）
 * ========================================================================== */
const http = require("http");
const { classify, beats, shuffleDeal } = require("./card-engine");

/* ---------- 内存存储 ---------- */
const rooms = new Map();       // room_code -> room
const stories = new Map();     // id -> {title, nodes: Map(node_key -> node), progress: Map(nick -> node_key)}
const admins = new Set(["admin"]);
let storySeq = 1;

/* 种子故事《勇者斗恶龙》 */
function seedStories() {
  const defs = [
    ["start", "你是一名年轻的勇者，站在巨龙山谷的入口。传说恶龙盘踞在山谷深处的古堡中，掳走了王国的小公主。你要如何开始你的冒险？", "小心潜入山谷", "forest", "大张旗鼓杀进去", "gate", 40, 120],
    ["forest", "你在茂密的森林中潜行，忽然发现一个受伤的老猎人。他愿意告诉你恶龙的弱点，作为回报，他希望你能带给他一株月光草。", "接受猎人的请求", "moonlight", "婉拒并独自前行", "cave", 250, 120],
    ["gate", "你挥舞着长剑冲向古堡大门，惊动了恶龙的守卫石像鬼。一场恶战即将开始！", "迎战石像鬼", "fight", "退回森林隐藏", "forest", 250, 320],
    ["moonlight", "你在月光下的湖边找到了月光草。老猎人告诉你：恶龙的护甲在月光下会变得脆弱。", "炼制月光药剂", "cave", "直接去找恶龙", "cave", 460, 120],
    ["cave", "你来到古堡深处的龙穴，恶龙正守护着沉睡的公主。你手中握着月光药剂，心跳如鼓。", "使用月光药剂攻击", "victory", "与恶龙谈判", "talk", 460, 320],
    ["fight", "你与石像鬼展开激战。经过一番苦战，你终于击败了它们，但也受了重伤。", "继续前进", "cave", "先疗伤再说", "forest", 460, 500],
    ["talk", "你试图与恶龙谈判。恶龙发出低沉的笑声：『勇士，公主其实是我自愿留下的！』", "相信恶龙", "ending_talk", "拔剑相向", "cave", 680, 120],
    ["victory", "你一剑刺穿恶龙的心脏，救出了公主。国王为你加冕！【结局：屠龙英雄】", null, null, null, null, 680, 320],
    ["ending_talk", "真相大白：原来真正的恶龙是公主的叔叔！你和公主联手击败了他。【结局：真相大白】", null, null, null, null, 680, 500]
  ];
  const s = { id: 1, title: "勇者斗恶龙", nodes: new Map(), progress: new Map() };
  defs.forEach(([k, c, oa, ta, ob, tb, x, y]) => {
    s.nodes.set(k, { node_key: k, content: c, option_a: oa, target_a: ta, option_b: ob, target_b: tb, pos_x: x, pos_y: y });
  });
  stories.set(1, s);
}

/* ---------- 工具 ---------- */
function genCode() {
  const chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  let c = "";
  for (let i = 0; i < 6; i++) c += chars[Math.floor(Math.random() * 32)];
  return c;
}
function deadline(sec) { return new Date(Date.now() + sec * 1000).toISOString(); }
function err(msg, code = 400) { const e = new Error(msg); e.code = code; return e; }
function roomView(room) {
  return { room_code: room.code, max_players: room.max, players: room.players, status: room.status, game_state: room.state, updated_at: new Date().toISOString() };
}
function nextSeat(state, from, n) {
  for (let off = 1; off <= n; off++) {
    const s = (from + off) % n;
    if ((state.hands[s] || []).length > 0) return s;
  }
  return from;
}
function isEndNode(n) { return !(n.option_a && n.target_a) && !(n.option_b && n.target_b); }

/* ---------- RPC 实现 ---------- */
const RPC = {
  is_admin: (b) => !!admins.has(b.p_nickname),

  create_room: (b) => {
    if (![2, 3, 4].includes(b.p_max_players)) throw err("人数只能为 2/3/4");
    if (!b.p_nickname || !String(b.p_nickname).trim()) throw err("昵称不能为空");
    let code;
    do { code = genCode(); } while (rooms.has(code));
    const room = {
      code, max: b.p_max_players, status: "waiting", state: null,
      players: [{ nickname: b.p_nickname, seat: 0, level: b.p_level || 1, is_host: true, cards_left: 0, left_hand: 0 }]
    };
    rooms.set(code, room);
    return roomView(room);
  },

  join_room: (b) => {
    const room = rooms.get(String(b.p_room_code || "").toUpperCase());
    if (!room) throw err("房间不存在");
    if (room.status !== "waiting") throw err("游戏已开始，无法加入");
    if (room.players.length >= room.max) throw err("房间已满");
    if (room.players.some(p => p.nickname === b.p_nickname)) throw err("该昵称已在此房间");
    room.players.push({ nickname: b.p_nickname, seat: room.players.length, level: b.p_level || 1, is_host: false, cards_left: 0, left_hand: 0 });
    return roomView(room);
  },

  leave_room: (b) => {
    const room = rooms.get(String(b.p_room_code || "").toUpperCase());
    if (!room) return null;
    const idx = room.players.findIndex(p => p.nickname === b.p_nickname);
    if (idx < 0) return roomView(room);
    room.players.splice(idx, 1);
    if (!room.players.length) { rooms.delete(room.code); return { room_code: room.code, destroyed: true }; }
    if (idx === 0) room.players[0].is_host = true;
    room.players.forEach((p, i) => { p.seat = i; });
    return roomView(room);
  },

  get_room: (b) => {
    const room = rooms.get(String(b.p_room_code || "").toUpperCase());
    return room ? roomView(room) : null;
  },

  start_game: (b) => {
    const room = rooms.get(String(b.p_room_code || "").toUpperCase());
    if (!room) throw err("房间不存在");
    if (room.players[0].nickname !== b.p_nickname) throw err("只有房主可以开始游戏");
    if (room.status !== "waiting") throw err("游戏已在进行");
    if (room.players.length < room.max) throw err("人数未满，无法开始");
    const { hands, base } = shuffleDeal(room.max);
    room.status = "playing";
    room.state = {
      phase: "bid", multiplier: 1, hands, base, landlord: null, current_seat: 0,
      bid_round: 0, bid_high: { seat: null, points: 0 }, bid_history: [], bid_retry: 0,
      last_play: null, pass_count: 0, turn_deadline: deadline(30), ended: null
    };
    return roomView(room);
  },

  bid: (b) => {
    const room = rooms.get(String(b.p_room_code || "").toUpperCase());
    if (!room) throw err("房间不存在");
    const st = room.state;
    if (room.status !== "playing" || st.phase !== "bid") throw err("不在叫地主阶段");
    const seat = room.players.findIndex(p => p.nickname === b.p_nickname);
    if (seat < 0) throw err("你不在本房间");
    if (seat !== st.current_seat) throw err("还没轮到你叫地主");
    if (![0, 1, 2, 3].includes(b.p_points)) throw err("叫分必须是 0/1/2/3");

    st.bid_history.push({ seat, points: b.p_points });
    if (b.p_points > (st.bid_high.points || 0)) st.bid_high = { seat, points: b.p_points };
    st.bid_round++;

    const n = room.players.length;
    if (st.bid_round >= n) {
      if (st.bid_high.seat != null && st.bid_high.points > 0) {
        const L = st.bid_high.seat;
        st.hands[L] = [...st.hands[L], ...st.base].sort((a, b) => a - b);
        st.landlord = L;
        st.multiplier = Math.max(st.bid_high.points, 1);
        st.phase = "playing";
        st.current_seat = L;
        st.pass_count = 0;
        st.last_play = null;
        st.turn_deadline = deadline(20);
      } else {
        st.bid_retry++;
        if (st.bid_retry >= 5) {
          const L = Math.floor(Math.random() * n);
          st.hands[L] = [...st.hands[L], ...st.base].sort((a, b) => a - b);
          st.landlord = L; st.multiplier = 1; st.phase = "playing";
          st.current_seat = L; st.pass_count = 0; st.last_play = null;
          st.bid_retry = 0; st.turn_deadline = deadline(20);
        } else {
          const d = shuffleDeal(room.max);
          Object.assign(st, { phase: "bid", multiplier: 1, hands: d.hands, base: d.base, landlord: null,
            current_seat: 0, bid_round: 0, bid_high: { seat: null, points: 0 }, bid_history: [],
            bid_retry: st.bid_retry, last_play: null, pass_count: 0, turn_deadline: deadline(30), ended: null });
        }
      }
    } else {
      st.current_seat = (st.current_seat + 1) % n;
      st.turn_deadline = deadline(30);
    }
    return roomView(room);
  },

  play_cards: (b) => {
    const room = rooms.get(String(b.p_room_code || "").toUpperCase());
    if (!room) throw err("房间不存在");
    const st = room.state;
    if (room.status !== "playing" || st.phase !== "playing") throw err("叫地主尚未结束");
    if (!b.p_cards || !b.p_cards.length) throw err("请选择要出的牌");
    const seat = room.players.findIndex(p => p.nickname === b.p_nickname);
    if (seat < 0) throw err("你不在本房间");
    if (seat !== st.current_seat) throw err("还没轮到你出牌");

    const cards = b.p_cards.map(Number);
    const hand = st.hands[seat];
    for (const v of cards) { if (!hand.includes(v)) throw err("出牌包含不在手牌中的牌"); }
    const counts = v => hand.filter(x => x === v).length;
    const playCounts = {};
    cards.forEach(v => playCounts[v] = (playCounts[v] || 0) + 1);
    for (const v of Object.keys(playCounts)) {
      if (playCounts[v] > counts(Number(v))) throw err("出牌张数超出持有数量");
    }
    const cls = classify(cards);
    if (!cls.ok) throw err("非法牌型");
    const lp = st.last_play;
    const free = !lp || lp.seat === seat;
    if (!free && !beats(lp, cls)) throw err("管不上上一手");

    /* 扣牌 */
    const remain = {};
    hand.forEach(v => remain[v] = (remain[v] || 0) + 1);
    cards.forEach(v => remain[v]--);
    const newHand = [];
    Object.keys(remain).map(Number).sort((a, b) => a - b).forEach(v => {
      for (let i = 0; i < remain[v]; i++) newHand.push(v);
    });
    st.hands[seat] = newHand;

    if (["bomb", "rocket"].includes(cls.type)) st.multiplier *= 2;
    st.last_play = { ...cls, seat, cards };
    st.pass_count = 0;

    if (newHand.length === 0) {
      const isLandlord = st.landlord === seat;
      st.ended = { winner: isLandlord ? "landlord" : "farmers", winner_seat: seat };
      room.status = "ended";
      return roomView(room);
    }

    st.current_seat = nextSeat(st, seat, room.players.length);
    st.turn_deadline = deadline(20);
    return roomView(room);
  },

  pass_turn: (b) => {
    const room = rooms.get(String(b.p_room_code || "").toUpperCase());
    if (!room) throw err("房间不存在");
    const st = room.state;
    if (room.status !== "playing" || st.phase !== "playing") throw err("叫地主尚未结束");
    const seat = room.players.findIndex(p => p.nickname === b.p_nickname);
    if (seat < 0) throw err("你不在本房间");
    if (seat !== st.current_seat) throw err("还没轮到你");
    const lp = st.last_play;
    if (!lp || lp.seat === seat) throw err("必须出牌");

    st.pass_count++;
    const nxt = nextSeat(st, seat, room.players.length);
    if (lp.seat === nxt) { st.last_play = null; st.pass_count = 0; }
    st.current_seat = nxt;
    st.turn_deadline = deadline(20);
    return roomView(room);
  },

  auto_pass: (b) => {
    const room = rooms.get(String(b.p_room_code || "").toUpperCase());
    if (!room) throw err("房间不存在");
    const st = room.state;
    if (room.status !== "playing" || st.phase !== "playing") return roomView(room);
    const cur = st.current_seat;
    const lp = st.last_play;
    if (lp && lp.seat !== cur) {
      return RPC.pass_turn({ p_room_code: room.code, p_nickname: room.players[cur].nickname });
    }
    const hand = st.hands[cur];
    const minV = Math.min(...hand);
    return RPC.play_cards({ p_room_code: room.code, p_nickname: room.players[cur].nickname, p_cards: [minV] });
  },

  /* ---- 文字冒险 ---- */
  list_stories: () => Array.from(stories.values()).map(s => ({
    id: s.id, title: s.title, created_at: new Date().toISOString(), node_count: s.nodes.size
  })),

  get_story_node: (b) => {
    const s = stories.get(Number(b.p_story_id));
    if (!s) return null;
    const n = s.nodes.get(b.p_node_key);
    if (!n) return null;
    return { story_id: s.id, node_key: n.node_key, content: n.content, option_a: n.option_a,
      target_a: n.target_a, option_b: n.option_b, target_b: n.target_b, is_end: isEndNode(n) };
  },

  save_story_progress: (b) => {
    if (!b.p_nickname || !String(b.p_nickname).trim()) throw err("昵称不能为空");
    const s = stories.get(Number(b.p_story_id));
    if (!s || !s.nodes.has(b.p_node_key)) throw err("目标节点不存在");
    s.progress.set(b.p_nickname, b.p_node_key);
    return { ok: true, nickname: b.p_nickname, story_id: s.id, current_node: b.p_node_key };
  },

  get_story_progress: (b) => {
    const s = stories.get(Number(b.p_story_id));
    if (!s || !s.progress.has(b.p_nickname)) return null;
    return { nickname: b.p_nickname, story_id: s.id, current_node: s.progress.get(b.p_nickname), updated_at: new Date().toISOString() };
  },

  create_story: (b) => {
    if (!b.p_title || !String(b.p_title).trim()) throw err("标题不能为空");
    const s = { id: storySeq++, title: String(b.p_title).trim(), nodes: new Map(), progress: new Map() };
    s.nodes.set("start", { node_key: "start", content: "（新故事的开始，请编辑这里的内容）", option_a: "继续", target_a: "start", option_b: null, target_b: null, pos_x: 0, pos_y: 0 });
    stories.set(s.id, s);
    return { id: s.id, title: s.title };
  },

  get_story_nodes: (b) => {
    const s = stories.get(Number(b.p_story_id));
    if (!s) return [];
    return Array.from(s.nodes.values()).map(n => ({ id: n.id || 0, ...n }));
  },

  save_story_node: (b) => {
    const s = stories.get(Number(b.p_story_id));
    if (!s) throw err("故事不存在");
    if (!b.p_content || !String(b.p_content).trim()) throw err("节点内容不能为空");
    if (!b.p_node_key || !String(b.p_node_key).trim()) throw err("节点 key 不能为空");
    s.nodes.set(b.p_node_key, {
      node_key: b.p_node_key, content: b.p_content, option_a: b.p_option_a || null,
      target_a: b.p_target_a || null, option_b: b.p_option_b || null, target_b: b.p_target_b || null,
      pos_x: b.p_pos_x || 0, pos_y: b.p_pos_y || 0
    });
    return { ok: true, story_id: s.id, node_key: b.p_node_key };
  },

  delete_story_node: (b) => {
    const s = stories.get(Number(b.p_story_id));
    if (!s) throw err("故事不存在");
    s.nodes.delete(b.p_node_key);
    s.nodes.forEach(n => { if (n.target_a === b.p_node_key) n.target_a = null; if (n.target_b === b.p_node_key) n.target_b = null; });
    return { ok: true, deleted_key: b.p_node_key };
  },

  delete_story: (b) => {
    stories.delete(Number(b.p_story_id));
    return { ok: true };
  }
};

/* ---------- HTTP 服务 ---------- */
const server = http.createServer((req, res) => {
  /* CORS 预检 */
  if (req.method === "OPTIONS") {
    res.writeHead(204, { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Methods": "POST,GET,OPTIONS", "Access-Control-Allow-Headers": "Content-Type,apikey,Authorization,Prefer" });
    res.end();
    return;
  }
  const m = req.url.match(/^\/rest\/v1\/rpc\/([\w]+)$/);
  if (!m) { res.writeHead(404); res.end(JSON.stringify({ message: "not found" })); return; }
  const fn = m[1];
  if (!RPC[fn]) { res.writeHead(404); res.end(JSON.stringify({ message: "unknown rpc " + fn })); return; }
  let body = "";
  req.on("data", c => body += c);
  req.on("end", () => {
    let parsed = {};
    try { parsed = body ? JSON.parse(body) : {}; } catch (e) {}
    try {
      const out = RPC[fn](parsed);
      res.writeHead(200, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" });
      res.end(JSON.stringify(out));
    } catch (e) {
      res.writeHead(e.code || 400, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" });
      res.end(JSON.stringify({ message: e.message }));
    }
  });
});

seedStories();
const PORT = process.env.PORT || 9090;
server.listen(PORT, () => console.log("SAMARRA mock supabase listening on :" + PORT));
