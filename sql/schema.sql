-- ============================================================================
-- SAMARRA 网页游戏平台 · 数据库全量重构脚本
-- 用法：打开 Supabase Dashboard → SQL Editor → 粘贴本文件全部内容 → Run
-- 本脚本会 DROP 所有旧表并重建，请确认后再执行。
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0) 清理：作废所有旧表 / 旧函数（旧数据全部丢弃）
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS story_progress;
DROP TABLE IF EXISTS story_nodes;
DROP TABLE IF EXISTS stories;
DROP TABLE IF EXISTS game_rooms;
DROP TABLE IF EXISTS admins;

DROP FUNCTION IF EXISTS is_admin(text);
DROP FUNCTION IF EXISTS create_room(int, text, int);
DROP FUNCTION IF EXISTS join_room(text, text, int);
DROP FUNCTION IF EXISTS leave_room(text, text);
DROP FUNCTION IF EXISTS get_room(text);
DROP FUNCTION IF EXISTS start_game(text, text);
DROP FUNCTION IF EXISTS bid(text, text, int);
DROP FUNCTION IF EXISTS play_cards(text, text, jsonb);
DROP FUNCTION IF EXISTS pass_turn(text, text);
DROP FUNCTION IF EXISTS auto_pass(text);
DROP FUNCTION IF EXISTS list_stories();
DROP FUNCTION IF EXISTS get_story_node(bigint, text);
DROP FUNCTION IF EXISTS save_story_progress(text, bigint, text);
DROP FUNCTION IF EXISTS get_story_progress(text, bigint);
DROP FUNCTION IF EXISTS create_story(text);
DROP FUNCTION IF EXISTS get_story_nodes(bigint);
DROP FUNCTION IF EXISTS save_story_node(bigint, text, text, text, text, text, text, double precision, double precision);
DROP FUNCTION IF EXISTS delete_story_node(bigint, text);
DROP FUNCTION IF EXISTS delete_story(bigint);

-- ---------------------------------------------------------------------------
-- 1) 建表
-- ---------------------------------------------------------------------------

-- 管理员表：记录特定昵称，只有匹配的昵称登录大厅才显示管理后台入口
CREATE TABLE admins (
  id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nickname    TEXT NOT NULL UNIQUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 游戏房间表（斗地主等通用房间）
CREATE TABLE game_rooms (
  id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  room_code   TEXT NOT NULL UNIQUE,
  max_players INTEGER NOT NULL DEFAULT 3 CHECK (max_players IN (2,3,4)),
  players     JSONB NOT NULL DEFAULT '[]'::jsonb,
  status      TEXT NOT NULL DEFAULT 'waiting' CHECK (status IN ('waiting','playing','ended')),
  game_state  JSONB,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 故事表
CREATE TABLE stories (
  id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  title      TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 剧情节点表（左右两个选项）
CREATE TABLE story_nodes (
  id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  story_id  BIGINT NOT NULL REFERENCES stories(id) ON DELETE CASCADE,
  node_key  TEXT NOT NULL,
  content   TEXT NOT NULL,
  option_a  TEXT,
  target_a  TEXT,
  option_b  TEXT,
  target_b  TEXT,
  pos_x     DOUBLE PRECISION NOT NULL DEFAULT 0,
  pos_y     DOUBLE PRECISION NOT NULL DEFAULT 0,
  UNIQUE(story_id, node_key)
);

-- 存档进度表（强绑定设备昵称）
CREATE TABLE story_progress (
  id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nickname     TEXT NOT NULL,
  story_id     BIGINT NOT NULL REFERENCES stories(id) ON DELETE CASCADE,
  current_node TEXT NOT NULL,
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(nickname, story_id)
);

-- 开启 RLS：前端一律通过 RPC 访问数据，表本身不对 anon 开放
ALTER TABLE admins        ENABLE ROW LEVEL SECURITY;
ALTER TABLE game_rooms    ENABLE ROW LEVEL SECURITY;
ALTER TABLE stories       ENABLE ROW LEVEL SECURITY;
ALTER TABLE story_nodes   ENABLE ROW LEVEL SECURITY;
ALTER TABLE story_progress ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- 2) 基础工具函数
-- ---------------------------------------------------------------------------

-- 是否管理员
CREATE OR REPLACE FUNCTION is_admin(p_nickname TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  RETURN EXISTS (SELECT 1 FROM admins WHERE nickname = p_nickname);
END $$;
GRANT EXECUTE ON FUNCTION is_admin(TEXT) TO anon, authenticated;

-- 生成不重复的 6 位房间码（去掉易混淆字符 0/O/1/I）
CREATE OR REPLACE FUNCTION _gen_room_code()
RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_code TEXT;
  v_tries INT := 0;
BEGIN
  LOOP
    v_tries := v_tries + 1;
    v_code := '';
    FOR i IN 1..6 LOOP
      v_code := v_code || substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', floor(random()*32)::int + 1, 1);
    END LOOP;
    EXIT WHEN NOT EXISTS (SELECT 1 FROM game_rooms WHERE room_code = v_code);
    IF v_tries > 100 THEN
      v_code := v_code || floor(random()*9000 + 1000)::text; -- 极端兜底，保证唯一
      EXIT;
    END IF;
  END LOOP;
  RETURN v_code;
END $$;

-- ---------------------------------------------------------------------------
-- 3) 牌型引擎（斗地主核心判定，全部在后端完成）
-- 牌值编码：3=3 ... 10=10, J=11, Q=12, K=13, A=14, 2=15, 小王=16, 大王=17
-- 返回 jsonb: {"ok":bool,"type":"single|pair|triple|triple_single|triple_pair|straight|straight_pair|airplane|airplane_single|airplane_pair|four_two|four_two_pair|bomb|rocket","value":int,"len":int,"err":"..."}
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION _classify(p_cards INT[])
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_sorted INT[];
  v_uniq INT[];
  v_n INT;
  v_k INT;
  v_cnt jsonb := '{}'::jsonb;
  v_i INT;
  v_v INT;
  v_c INT;
  v_min INT;
  v_max INT;
  v_bad BOOLEAN;
BEGIN
  v_n := coalesce(cardinality(p_cards), 0);
  IF v_n = 0 THEN
    RETURN jsonb_build_object('ok', false, 'err', 'empty');
  END IF;

  -- 排序 + 计数
  SELECT array_agg(x ORDER BY x) INTO v_sorted FROM unnest(p_cards) AS x;
  FOR v_i IN 1..v_n LOOP
    v_v := v_sorted[v_i];
    v_c := coalesce((v_cnt->>v_v::text)::int, 0) + 1;
    v_cnt := jsonb_set(v_cnt, ARRAY[v_v::text], to_jsonb(v_c));
  END LOOP;
  SELECT array_agg(k::int ORDER BY k::int) INTO v_uniq FROM jsonb_object_keys(v_cnt) AS k;
  v_k := cardinality(v_uniq);
  v_min := v_uniq[1];
  v_max := v_uniq[v_k];

  -- 单张
  IF v_n = 1 THEN
    RETURN jsonb_build_object('ok', true, 'type', 'single', 'value', v_sorted[1], 'len', 1);
  END IF;

  -- 火箭（王炸）
  IF v_n = 2 AND v_sorted[1] = 16 AND v_sorted[2] = 17 THEN
    RETURN jsonb_build_object('ok', true, 'type', 'rocket', 'value', 99, 'len', 2);
  END IF;

  -- 对子
  IF v_n = 2 AND v_k = 1 THEN
    RETURN jsonb_build_object('ok', true, 'type', 'pair', 'value', v_max, 'len', 2);
  END IF;

  -- 三张
  IF v_n = 3 AND v_k = 1 THEN
    RETURN jsonb_build_object('ok', true, 'type', 'triple', 'value', v_max, 'len', 3);
  END IF;

  -- 炸弹 / 三带一
  IF v_n = 4 THEN
    IF v_k = 1 THEN
      RETURN jsonb_build_object('ok', true, 'type', 'bomb', 'value', v_max, 'len', 4);
    END IF;
    -- 三带一（3+1）
    IF v_k = 2 THEN
      v_v := 0;
      FOR v_i IN 1..v_k LOOP
        IF (v_cnt->>v_uniq[v_i]::text)::int = 3 THEN v_v := v_uniq[v_i]; END IF;
      END LOOP;
      IF v_v > 0 THEN
        RETURN jsonb_build_object('ok', true, 'type', 'triple_single', 'value', v_v, 'len', 4);
      END IF;
    END IF;
    RETURN jsonb_build_object('ok', false, 'err', 'invalid 4-cards');
  END IF;

  -- 三带二（3+2）
  IF v_n = 5 THEN
    IF v_k = 2 AND ((v_cnt->>v_min::text)::int = 3 OR (v_cnt->>v_max::text)::int = 3) THEN
      v_v := CASE WHEN (v_cnt->>v_min::text)::int = 3 THEN v_min ELSE v_max END;
      RETURN jsonb_build_object('ok', true, 'type', 'triple_pair', 'value', v_v, 'len', 5);
    END IF;
    -- 顺子 5 张
    IF v_k = 5 AND v_max <= 14 AND v_max - v_min = 4 THEN
      RETURN jsonb_build_object('ok', true, 'type', 'straight', 'value', v_max, 'len', 5);
    END IF;
    RETURN jsonb_build_object('ok', false, 'err', 'invalid 5-cards');
  END IF;

  -- 四带两单（6 张：4+1+1）
  IF v_n = 6 THEN
    -- 四张存在
    v_v := 0;
    FOR v_i IN 1..v_k LOOP
      IF (v_cnt->>v_uniq[v_i]::text)::int = 4 THEN v_v := v_uniq[v_i]; END IF;
    END LOOP;
    IF v_v > 0 THEN
      RETURN jsonb_build_object('ok', true, 'type', 'four_two', 'value', v_v, 'len', 6);
    END IF;
    -- 连对 3 组（3×2）
    IF v_k = 3 AND v_max <= 14 AND v_max - v_min = 2 THEN
      v_bad := false;
      FOR v_i IN 1..v_k LOOP
        IF (v_cnt->>v_uniq[v_i]::text)::int <> 2 THEN v_bad := true; END IF;
      END LOOP;
      IF NOT v_bad THEN
        RETURN jsonb_build_object('ok', true, 'type', 'straight_pair', 'value', v_max, 'len', 6);
      END IF;
    END IF;
    -- 飞机不带翼（2×3）
    IF v_k = 2 AND v_max <= 14 AND v_max - v_min = 1 AND
       (v_cnt->>v_min::text)::int = 3 AND (v_cnt->>v_max::text)::int = 3 THEN
      RETURN jsonb_build_object('ok', true, 'type', 'airplane', 'value', v_max, 'len', 6);
    END IF;
    RETURN jsonb_build_object('ok', false, 'err', 'invalid 6-cards');
  END IF;

  -- 8 张：四带两对 / 飞机带单翼(2组×3+2翼) / 连对 4 组
  IF v_n = 8 THEN
    -- 四带两对（4+2+2）
    v_v := 0;
    v_bad := false;
    FOR v_i IN 1..v_k LOOP
      v_c := (v_cnt->>v_uniq[v_i]::text)::int;
      IF v_c = 4 THEN v_v := v_uniq[v_i];
      ELSIF v_c <> 2 THEN v_bad := true;
      END IF;
    END LOOP;
    IF v_v > 0 AND NOT v_bad AND v_k = 3 THEN
      RETURN jsonb_build_object('ok', true, 'type', 'four_two_pair', 'value', v_v, 'len', 8);
    END IF;
    -- 连对 4 组
    IF v_k = 4 AND v_max <= 14 AND v_max - v_min = 3 THEN
      v_bad := false;
      FOR v_i IN 1..v_k LOOP
        IF (v_cnt->>v_uniq[v_i]::text)::int <> 2 THEN v_bad := true; END IF;
      END LOOP;
      IF NOT v_bad THEN
        RETURN jsonb_build_object('ok', true, 'type', 'straight_pair', 'value', v_max, 'len', 8);
      END IF;
    END IF;
    -- 飞机带单翼（2 组三连 + 2 张翼）——由下方通用分支处理，此处保留快速路径
    IF v_k >= 3 AND v_max <= 14 THEN
      FOR v_i IN 1..(v_k-1) LOOP
        IF (v_cnt->>v_uniq[v_i]::text)::int = 3 AND (v_cnt->>v_uniq[v_i+1]::text)::int = 3
           AND v_uniq[v_i+1] - v_uniq[v_i] = 1 THEN
          RETURN jsonb_build_object('ok', true, 'type', 'airplane_single', 'value', v_uniq[v_i+1], 'len', 8);
        END IF;
      END LOOP;
    END IF;
    RETURN jsonb_build_object('ok', false, 'err', 'invalid 8-cards');
  END IF;

  -- 顺子（5~12 连，不含 2 与王）
  IF v_n >= 5 AND v_n <= 12 AND v_k = v_n AND v_max <= 14 AND v_max - v_min = v_n - 1 THEN
    RETURN jsonb_build_object('ok', true, 'type', 'straight', 'value', v_max, 'len', v_n);
  END IF;

  -- 连对（n/2 组，每组 2 张，n>=6 偶数）
  IF v_n >= 6 AND v_n % 2 = 0 AND v_k = v_n / 2 AND v_n / 2 >= 3 AND v_max <= 14 AND v_max - v_min = v_k - 1 THEN
    v_bad := false;
    FOR v_i IN 1..v_k LOOP
      IF (v_cnt->>v_uniq[v_i]::text)::int <> 2 THEN v_bad := true; END IF;
    END LOOP;
    IF NOT v_bad THEN
      RETURN jsonb_build_object('ok', true, 'type', 'straight_pair', 'value', v_max, 'len', v_n);
    END IF;
  END IF;

  -- 飞机（n%3=0，k=n/3 组三连，n>=6）
  IF v_n >= 6 AND v_n % 3 = 0 AND v_k = v_n / 3 AND v_k >= 2 AND v_max <= 14 AND v_max - v_min = v_k - 1 THEN
    v_bad := false;
    FOR v_i IN 1..v_k LOOP
      IF (v_cnt->>v_uniq[v_i]::text)::int <> 3 THEN v_bad := true; END IF;
    END LOOP;
    IF NOT v_bad THEN
      RETURN jsonb_build_object('ok', true, 'type', 'airplane', 'value', v_max, 'len', v_n);
    END IF;
  END IF;

  -- 飞机带单翼（n%4=0，k=n/4 组三连 + k 张翼，n>=8）
  IF v_n >= 8 AND v_n % 4 = 0 THEN
    v_k := v_n / 4;
    FOR v_i IN 1..(cardinality(v_uniq) - v_k + 1) LOOP
      IF v_uniq[v_i + v_k - 1] <= 14 AND v_uniq[v_i + v_k - 1] - v_uniq[v_i] = v_k - 1 THEN
        v_bad := false;
        FOR v_j IN v_i..(v_i + v_k - 1) LOOP
          IF (v_cnt->>v_uniq[v_j]::text)::int <> 3 THEN v_bad := true; END IF;
        END LOOP;
        IF NOT v_bad THEN
          RETURN jsonb_build_object('ok', true, 'type', 'airplane_single', 'value', v_uniq[v_i + v_k - 1], 'len', v_n);
        END IF;
      END IF;
    END LOOP;
  END IF;

  -- 飞机带对翼（n%5=0，k=n/5 组三连 + k 组对翼，n>=10）
  IF v_n >= 10 AND v_n % 5 = 0 THEN
    v_k := v_n / 5;
    FOR v_i IN 1..(cardinality(v_uniq) - v_k + 1) LOOP
      IF v_uniq[v_i + v_k - 1] <= 14 AND v_uniq[v_i + v_k - 1] - v_uniq[v_i] = v_k - 1 THEN
        v_bad := false;
        FOR v_j IN v_i..(v_i + v_k - 1) LOOP
          IF (v_cnt->>v_uniq[v_j]::text)::int <> 3 THEN v_bad := true; END IF;
        END LOOP;
        FOR v_j IN 1..cardinality(v_uniq) LOOP
          IF v_j < v_i OR v_j > v_i + v_k - 1 THEN
            IF (v_cnt->>v_uniq[v_j]::text)::int <> 2 THEN v_bad := true; END IF;
          END IF;
        END LOOP;
        IF NOT v_bad THEN
          RETURN jsonb_build_object('ok', true, 'type', 'airplane_pair', 'value', v_uniq[v_i + v_k - 1], 'len', v_n);
        END IF;
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object('ok', false, 'err', 'invalid combination');
END $$;

-- 一手牌能否压过上一手
CREATE OR REPLACE FUNCTION _beats(p_last jsonb, p_cur jsonb)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_last_type TEXT;
  v_cur_type TEXT;
BEGIN
  IF p_last IS NULL OR (p_last->>'type') IS NULL THEN
    RETURN true; -- 自由出牌
  END IF;
  v_last_type := p_last->>'type';
  v_cur_type := p_cur->>'type';
  IF v_cur_type = 'rocket' THEN
    RETURN v_last_type <> 'rocket'; -- 王炸最大，只有王炸平局
  END IF;
  IF v_last_type = 'rocket' THEN RETURN false; END IF;
  IF v_cur_type = 'bomb' THEN
    IF v_last_type = 'bomb' THEN RETURN (p_cur->>'value')::int > (p_last->>'value')::int; END IF;
    RETURN true;
  END IF;
  IF v_last_type = 'bomb' THEN RETURN false; END IF;
  IF v_cur_type = v_last_type AND (p_cur->>'len')::int = (p_last->>'len')::int THEN
    RETURN (p_cur->>'value')::int > (p_last->>'value')::int;
  END IF;
  RETURN false;
END $$;

-- 洗牌 + 发牌。返回 jsonb {"hands":{seat:[...]},"base":[..]}，每人手牌已排序
CREATE OR REPLACE FUNCTION _shuffle_deal(p_max_players INT)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_decks INT := CASE WHEN p_max_players = 4 THEN 2 ELSE 1 END;
  v_deck INT[] := '{}'::int[];
  v_shuffled INT[] := '{}'::int[];
  v_hand INT[] := '{}'::int[];
  v_hands jsonb := '{}'::jsonb;
  v_base INT[] := '{}'::int[];
  v_per INT;
  v_base_cnt INT;
  v_i INT;
  v_j INT;
  v_p INT;
  v_idx INT;
BEGIN
  -- 组牌：3..15 每值 4 张（52 张）+ 小王(16) + 大王(17) = 一副 54 张
  FOR v_i IN 1..v_decks LOOP
    FOR v_j IN 3..15 LOOP
      FOR v_p IN 1..4 LOOP
        v_deck := array_append(v_deck, v_j);
      END LOOP;
    END LOOP;
    v_deck := array_append(v_deck, 16);
    v_deck := array_append(v_deck, 17);
  END LOOP;
  -- Fisher-Yates 洗牌（Postgres FOR REVERSE 语法）
  FOR v_i IN REVERSE cardinality(v_deck)..2 LOOP
    v_j := 1 + floor(random() * v_i)::int;
    v_p := v_deck[v_i];
    v_deck[v_i] := v_deck[v_j];
    v_deck[v_j] := v_p;
  END LOOP;
  -- 每人张数与底牌
  IF p_max_players = 2 THEN v_per := 20; v_base_cnt := 4;
  ELSIF p_max_players = 3 THEN v_per := 17; v_base_cnt := 3;
  ELSE v_per := 25; v_base_cnt := 8;
  END IF;
  -- 发牌
  v_idx := 1;
  FOR v_i IN 0..(p_max_players - 1) LOOP
    v_hand := '{}'::int[];
    FOR v_j IN 1..v_per LOOP
      v_hand := array_append(v_hand, v_deck[v_idx]);
      v_idx := v_idx + 1;
    END LOOP;
    SELECT array_agg(x ORDER BY x) INTO v_hand FROM unnest(v_hand) AS x;
    v_hands := jsonb_set(v_hands, ARRAY[v_i::text], to_jsonb(v_hand));
  END LOOP;
  FOR v_j IN 1..v_base_cnt LOOP
    v_base := array_append(v_base, v_deck[v_idx]);
    v_idx := v_idx + 1;
  END LOOP;
  SELECT array_agg(x ORDER BY x) INTO v_base FROM unnest(v_base) AS x;
  RETURN jsonb_build_object('hands', v_hands, 'base', v_base);
END $$;

-- 轮转：拿到下一个座位号（跳过已出完的玩家）
CREATE OR REPLACE FUNCTION _next_seat(p_state jsonb, p_from INT, p_players jsonb)
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_n INT := jsonb_array_length(p_players);
  v_i INT;
  v_off INT;
BEGIN
  FOR v_off IN 1..v_n LOOP
    v_i := (p_from + v_off) % v_n;
    -- 跳过已出完牌的玩家
    IF (p_state->'hands'->v_i::text) IS NOT NULL
       AND jsonb_array_length(p_state->'hands'->v_i::text) > 0 THEN
      RETURN v_i;
    END IF;
  END LOOP;
  RETURN p_from;
END $$;

-- ---------------------------------------------------------------------------
-- 4) 房间 RPC：创建 / 加入 / 离开 / 查询 / 开始 / 叫地主 / 出牌 / 过牌 / 超时
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION create_room(p_max_players INT, p_nickname TEXT, p_level INT DEFAULT 1)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_code TEXT;
  v_room game_rooms%ROWTYPE;
  v_players jsonb;
BEGIN
  IF p_max_players NOT IN (2,3,4) THEN
    RAISE EXCEPTION '人数只能为 2/3/4';
  END IF;
  IF p_nickname IS NULL OR length(trim(p_nickname)) = 0 THEN
    RAISE EXCEPTION '昵称不能为空';
  END IF;
  v_code := _gen_room_code();
  v_players := jsonb_build_array(
    jsonb_build_object('nickname', p_nickname, 'seat', 0, 'level', coalesce(p_level,1),
                       'is_host', true, 'cards_left', 0, 'left_hand', 0)
  );
  INSERT INTO game_rooms (room_code, max_players, players, status, game_state)
  VALUES (v_code, p_max_players, v_players, 'waiting', NULL)
  RETURNING * INTO v_room;
  RETURN jsonb_build_object(
    'room_code', v_room.room_code, 'max_players', v_room.max_players,
    'players', v_room.players, 'status', v_room.status,
    'game_state', v_room.game_state, 'updated_at', v_room.updated_at
  );
END $$;
GRANT EXECUTE ON FUNCTION create_room(INT, TEXT, INT) TO anon, authenticated;

CREATE OR REPLACE FUNCTION join_room(p_room_code TEXT, p_nickname TEXT, p_level INT DEFAULT 1)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_room game_rooms%ROWTYPE;
  v_players jsonb;
  v_seat INT;
  v_i INT;
BEGIN
  IF p_nickname IS NULL OR length(trim(p_nickname)) = 0 THEN
    RAISE EXCEPTION '昵称不能为空';
  END IF;
  SELECT * INTO v_room FROM game_rooms WHERE upper(room_code) = upper(p_room_code) FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION '房间不存在'; END IF;
  IF v_room.status <> 'waiting' THEN RAISE EXCEPTION '游戏已开始，无法加入'; END IF;
  IF jsonb_array_length(v_room.players) >= v_room.max_players THEN RAISE EXCEPTION '房间已满'; END IF;
  FOR v_i IN 0..(jsonb_array_length(v_room.players) - 1) LOOP
    IF v_room.players->v_i->>'nickname' = p_nickname THEN RAISE EXCEPTION '该昵称已在此房间'; END IF;
  END LOOP;
  v_seat := jsonb_array_length(v_room.players);
  v_players := v_room.players || jsonb_build_object(
    'nickname', p_nickname, 'seat', v_seat, 'level', coalesce(p_level,1),
    'is_host', false, 'cards_left', 0, 'left_hand', 0
  );
  UPDATE game_rooms SET players = v_players, updated_at = now()
  WHERE id = v_room.id RETURNING * INTO v_room;
  RETURN jsonb_build_object(
    'room_code', v_room.room_code, 'max_players', v_room.max_players,
    'players', v_room.players, 'status', v_room.status,
    'game_state', v_room.game_state, 'updated_at', v_room.updated_at
  );
END $$;
GRANT EXECUTE ON FUNCTION join_room(TEXT, TEXT, INT) TO anon, authenticated;

CREATE OR REPLACE FUNCTION leave_room(p_room_code TEXT, p_nickname TEXT)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_room game_rooms%ROWTYPE;
  v_players jsonb := '[]'::jsonb;
  v_new_host TEXT := NULL;
  v_i INT;
  v_found BOOLEAN := false;
  v_was_host BOOLEAN := false;
BEGIN
  SELECT * INTO v_room FROM game_rooms WHERE upper(room_code) = upper(p_room_code) FOR UPDATE;
  IF NOT FOUND THEN RETURN NULL; END IF;
  -- 过滤掉该玩家
  FOR v_i IN 0..(jsonb_array_length(v_room.players) - 1) LOOP
    IF v_room.players->v_i->>'nickname' = p_nickname THEN
      v_found := true;
      v_was_host := coalesce((v_room.players->v_i->>'is_host')::boolean, false);
    ELSE
      v_players := v_players || v_room.players->v_i;
    END IF;
  END LOOP;
  IF NOT v_found THEN
    RETURN jsonb_build_object('room_code', v_room.room_code, 'players', v_room.players,
                              'status', v_room.status, 'game_state', v_room.game_state,
                              'max_players', v_room.max_players, 'updated_at', v_room.updated_at);
  END IF;
  IF jsonb_array_length(v_players) = 0 THEN
    DELETE FROM game_rooms WHERE id = v_room.id;
    RETURN jsonb_build_object('room_code', v_room.room_code, 'destroyed', true);
  END IF;
  -- 房主离开：转交（重新编号座位）
  IF v_was_host THEN
    v_players := jsonb_set(v_players, ARRAY[0::text],
      (v_players->0) || jsonb_build_object('is_host', true));
  END IF;
  -- 重排 seat
  FOR v_i IN 0..(jsonb_array_length(v_players) - 1) LOOP
    v_players := jsonb_set(v_players, ARRAY[v_i::text],
      (v_players->v_i) || jsonb_build_object('seat', v_i));
  END LOOP;
  UPDATE game_rooms SET players = v_players, updated_at = now()
  WHERE id = v_room.id RETURNING * INTO v_room;
  RETURN jsonb_build_object(
    'room_code', v_room.room_code, 'max_players', v_room.max_players,
    'players', v_room.players, 'status', v_room.status,
    'game_state', v_room.game_state, 'updated_at', v_room.updated_at
  );
END $$;
GRANT EXECUTE ON FUNCTION leave_room(TEXT, TEXT) TO anon, authenticated;

CREATE OR REPLACE FUNCTION get_room(p_room_code TEXT)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_room game_rooms%ROWTYPE;
BEGIN
  SELECT * INTO v_room FROM game_rooms WHERE upper(room_code) = upper(p_room_code);
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN jsonb_build_object(
    'room_code', v_room.room_code, 'max_players', v_room.max_players,
    'players', v_room.players, 'status', v_room.status,
    'game_state', v_room.game_state, 'updated_at', v_room.updated_at
  );
END $$;
GRANT EXECUTE ON FUNCTION get_room(TEXT) TO anon, authenticated;

-- 开始游戏：房主触发，洗牌发牌进入叫地主阶段
CREATE OR REPLACE FUNCTION start_game(p_room_code TEXT, p_nickname TEXT)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_room game_rooms%ROWTYPE;
  v_deal jsonb;
  v_state jsonb;
  v_host TEXT;
BEGIN
  SELECT * INTO v_room FROM game_rooms WHERE upper(room_code) = upper(p_room_code) FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION '房间不存在'; END IF;
  v_host := v_room.players->0->>'nickname';
  IF v_host <> p_nickname THEN RAISE EXCEPTION '只有房主可以开始游戏'; END IF;
  IF v_room.status <> 'waiting' THEN RAISE EXCEPTION '游戏已在进行'; END IF;
  IF jsonb_array_length(v_room.players) < v_room.max_players THEN
    RAISE EXCEPTION '人数未满，无法开始';
  END IF;
  v_deal := _shuffle_deal(v_room.max_players);
  v_state := jsonb_build_object(
    'phase', 'bid',
    'multiplier', 1,
    'hands', v_deal->'hands',
    'base', v_deal->'base',
    'landlord', NULL,
    'current_seat', 0,
    'bid_round', 0,
    'bid_high', jsonb_build_object('seat', NULL, 'points', 0),
    'bid_history', '[]'::jsonb,
    'bid_retry', 0,
    'last_play', NULL,
    'pass_count', 0,
    'turn_deadline', to_char(now() + interval '30 seconds', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'ended', NULL
  );
  UPDATE game_rooms SET status = 'playing', game_state = v_state, updated_at = now()
  WHERE id = v_room.id RETURNING * INTO v_room;
  RETURN jsonb_build_object(
    'room_code', v_room.room_code, 'max_players', v_room.max_players,
    'players', v_room.players, 'status', v_room.status,
    'game_state', v_room.game_state, 'updated_at', v_room.updated_at
  );
END $$;
GRANT EXECUTE ON FUNCTION start_game(TEXT, TEXT) TO anon, authenticated;

-- 叫地主：p_points ∈ {0(不叫),1,2,3}
CREATE OR REPLACE FUNCTION bid(p_room_code TEXT, p_nickname TEXT, p_points INT)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_room game_rooms%ROWTYPE;
  v_state jsonb;
  v_seat INT := -1;
  v_cur INT;
  v_n INT;
  v_i INT;
  v_high_seat INT;
  v_high_pts INT;
  v_hand_arr INT[];
  v_base INT[];
  v_landlord INT;
  v_retry INT;
  v_deal jsonb;
BEGIN
  SELECT * INTO v_room FROM game_rooms WHERE upper(room_code) = upper(p_room_code) FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION '房间不存在'; END IF;
  IF v_room.status <> 'playing' THEN RAISE EXCEPTION '游戏不在进行中'; END IF;
  v_state := v_room.game_state;
  IF v_state->>'phase' <> 'bid' THEN RAISE EXCEPTION '不在叫地主阶段'; END IF;
  -- 找到该昵称的座位
  v_n := jsonb_array_length(v_room.players);
  FOR v_i IN 0..(v_n - 1) LOOP
    IF v_room.players->v_i->>'nickname' = p_nickname THEN v_seat := v_i; END IF;
  END LOOP;
  IF v_seat < 0 THEN RAISE EXCEPTION '你不在本房间'; END IF;
  v_cur := (v_state->>'current_seat')::int;
  IF v_seat <> v_cur THEN RAISE EXCEPTION '还没轮到你叫地主'; END IF;
  IF p_points NOT IN (0,1,2,3) THEN RAISE EXCEPTION '叫分必须是 0/1/2/3'; END IF;

  -- 记录叫分
  v_state := jsonb_set(v_state, ARRAY['bid_history'],
    (v_state->'bid_history') || jsonb_build_array(jsonb_build_object('seat', v_seat, 'points', p_points)));
  v_high_seat := (v_state->'bid_high'->>'seat')::int;
  v_high_pts := (v_state->'bid_high'->>'points')::int;
  IF v_high_seat IS NULL OR p_points > v_high_pts THEN
    v_state := jsonb_set(v_state, ARRAY['bid_high'],
      jsonb_build_object('seat', v_seat, 'points', p_points));
  END IF;
  v_state := jsonb_set(v_state, ARRAY['bid_round'], to_jsonb((v_state->>'bid_round')::int + 1));

  -- 轮转判断：是否所有人都叫过（max_players 人各叫一次）
  IF (v_state->>'bid_round')::int >= v_n THEN
    v_high_seat := (v_state->'bid_high'->>'seat')::int;
    v_high_pts := (v_state->'bid_high'->>'points')::int;
    IF v_high_seat IS NOT NULL AND v_high_pts > 0 THEN
      -- 定地主：底牌并入地主手牌
      v_landlord := v_high_seat;
      SELECT array_agg(e::int ORDER BY e::int) INTO v_hand_arr
      FROM (
        SELECT e::int FROM jsonb_array_elements_text(v_state->'hands'->v_landlord::text) AS e
        UNION ALL
        SELECT e FROM unnest(ARRAY(SELECT jsonb_array_elements_text(v_state->'base')::int)) AS e
      ) t;
      v_state := jsonb_set(v_state, ARRAY['hands', v_landlord::text], to_jsonb(v_hand_arr));
      v_state := jsonb_set(v_state, ARRAY['landlord'], to_jsonb(v_landlord));
      v_state := jsonb_set(v_state, ARRAY['multiplier'], to_jsonb(greatest(v_high_pts, 1)));
      v_state := jsonb_set(v_state, ARRAY['phase'], to_jsonb('playing'));
      v_state := jsonb_set(v_state, ARRAY['current_seat'], to_jsonb(v_landlord));
      v_state := jsonb_set(v_state, ARRAY['pass_count'], to_jsonb(0));
      v_state := jsonb_set(v_state, ARRAY['last_play'], 'null'::jsonb);
      v_state := jsonb_set(v_state, ARRAY['turn_deadline'],
        to_jsonb(to_char(now() + interval '20 seconds', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')));
    ELSE
      -- 全部不叫：重新洗牌发牌重来（最多 5 次后强制随机地主）
      v_retry := (v_state->>'bid_retry')::int + 1;
      IF v_retry >= 5 THEN
        -- 强制随机地主
        v_landlord := floor(random() * v_n)::int;
        SELECT array_agg(e::int ORDER BY e::int) INTO v_hand_arr
        FROM (
          SELECT e::int FROM jsonb_array_elements_text(v_state->'hands'->v_landlord::text) AS e
          UNION ALL
          SELECT e FROM unnest(ARRAY(SELECT jsonb_array_elements_text(v_state->'base')::int)) AS e
        ) t;
        v_state := jsonb_set(v_state, ARRAY['hands', v_landlord::text], to_jsonb(v_hand_arr));
        v_state := jsonb_set(v_state, ARRAY['landlord'], to_jsonb(v_landlord));
        v_state := jsonb_set(v_state, ARRAY['multiplier'], to_jsonb(1));
        v_state := jsonb_set(v_state, ARRAY['phase'], to_jsonb('playing'));
        v_state := jsonb_set(v_state, ARRAY['current_seat'], to_jsonb(v_landlord));
        v_state := jsonb_set(v_state, ARRAY['pass_count'], to_jsonb(0));
        v_state := jsonb_set(v_state, ARRAY['last_play'], 'null'::jsonb);
        v_state := jsonb_set(v_state, ARRAY['bid_retry'], to_jsonb(0));
        v_state := jsonb_set(v_state, ARRAY['turn_deadline'],
          to_jsonb(to_char(now() + interval '20 seconds', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')));
      ELSE
        v_deal := _shuffle_deal(v_room.max_players);
        v_state := jsonb_build_object(
          'phase', 'bid', 'multiplier', 1,
          'hands', v_deal->'hands', 'base', v_deal->'base',
          'landlord', NULL, 'current_seat', 0,
          'bid_round', 0,
          'bid_high', jsonb_build_object('seat', NULL, 'points', 0),
          'bid_history', '[]'::jsonb,
          'bid_retry', v_retry,
          'last_play', NULL, 'pass_count', 0,
          'turn_deadline', to_char(now() + interval '30 seconds', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
          'ended', NULL);
      END IF;
    END IF;
  ELSE
    -- 轮到下一个座位
    v_state := jsonb_set(v_state, ARRAY['current_seat'], to_jsonb((v_cur + 1) % v_n));
    v_state := jsonb_set(v_state, ARRAY['turn_deadline'],
      to_jsonb(to_char(now() + interval '30 seconds', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')));
  END IF;

  UPDATE game_rooms SET game_state = v_state, updated_at = now() WHERE id = v_room.id
  RETURNING * INTO v_room;
  RETURN jsonb_build_object(
    'room_code', v_room.room_code, 'max_players', v_room.max_players,
    'players', v_room.players, 'status', v_room.status,
    'game_state', v_room.game_state, 'updated_at', v_room.updated_at
  );
END $$;
GRANT EXECUTE ON FUNCTION bid(TEXT, TEXT, INT) TO anon, authenticated;

-- 出牌：p_cards 为 int[]（jsonb 数组）
CREATE OR REPLACE FUNCTION play_cards(p_room_code TEXT, p_nickname TEXT, p_cards jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_room game_rooms%ROWTYPE;
  v_state jsonb;
  v_seat INT := -1;
  v_cur INT;
  v_n INT;
  v_i INT;
  v_cards INT[] := '{}'::int[];
  v_hand jsonb;
  v_cls jsonb;
  v_last jsonb;
  v_last_seat INT;
  v_free BOOLEAN := false;
  v_winner_seat INT;
  v_is_landlord BOOLEAN;
  v_winner TEXT;
  v_new_hand jsonb;
  v_next INT;
  v_deadline TEXT;
  v_card INT;
  v_play_cnt INT;
  v_hand_cnt INT;
  v_j INT;
BEGIN
  SELECT * INTO v_room FROM game_rooms WHERE upper(room_code) = upper(p_room_code) FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION '房间不存在'; END IF;
  IF v_room.status <> 'playing' THEN RAISE EXCEPTION '游戏不在进行中'; END IF;
  v_state := v_room.game_state;
  IF v_state->>'phase' <> 'playing' THEN RAISE EXCEPTION '叫地主尚未结束'; END IF;
  IF p_cards IS NULL OR jsonb_array_length(p_cards) = 0 THEN RAISE EXCEPTION '请选择要出的牌'; END IF;

  v_n := jsonb_array_length(v_room.players);
  FOR v_i IN 0..(v_n - 1) LOOP
    IF v_room.players->v_i->>'nickname' = p_nickname THEN v_seat := v_i; END IF;
  END LOOP;
  IF v_seat < 0 THEN RAISE EXCEPTION '你不在本房间'; END IF;
  v_cur := (v_state->>'current_seat')::int;
  IF v_seat <> v_cur THEN RAISE EXCEPTION '还没轮到你出牌'; END IF;

  -- 转 int 数组并校验都在手牌里
  SELECT array_agg(x::int) INTO v_cards FROM jsonb_array_elements_text(p_cards) AS x;
  v_hand := v_state->'hands'->v_seat::text;
  FOR v_i IN 1..cardinality(v_cards) LOOP
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_hand) AS h(x) WHERE h.x::int = v_cards[v_i]) THEN
      RAISE EXCEPTION '出牌包含不在手牌中的牌';
    END IF;
  END LOOP;
  -- 重复张数校验（手牌中该牌数量必须 ≥ 出牌中该牌数量）
  FOR v_i IN 1..cardinality(v_cards) LOOP
    IF (SELECT count(*) FROM unnest(v_cards) u WHERE u = v_cards[v_i])
       > (SELECT count(*) FROM jsonb_array_elements_text(v_hand) h WHERE h.x::int = v_cards[v_i]) THEN
      RAISE EXCEPTION '出牌张数超出持有数量';
    END IF;
  END LOOP;

  -- 牌型校验
  v_cls := _classify(v_cards);
  IF NOT (v_cls->>'ok')::boolean THEN
    RAISE EXCEPTION '非法牌型';
  END IF;

  -- 压牌校验：若上一手是空/已清空 → 自由出；若轮到的人与上一手出牌人相同 → 自由出
  v_last := v_state->'last_play';
  IF v_last = 'null'::jsonb OR v_last IS NULL THEN
    v_free := true;
  ELSIF (v_last->>'seat')::int = v_seat THEN
    v_free := true;
  ELSE
    IF NOT _beats(v_last, v_cls) THEN
      RAISE EXCEPTION '管不上上一手';
    END IF;
  END IF;

  -- 扣牌（按数量扣减，保证重复牌处理正确）
  v_new_hand := '[]'::jsonb;
  FOR v_card IN SELECT DISTINCT x::int FROM jsonb_array_elements_text(v_hand) AS x ORDER BY 1 LOOP
    v_play_cnt := (SELECT count(*) FROM unnest(v_cards) c WHERE c = v_card);
    v_hand_cnt := (SELECT count(*) FROM jsonb_array_elements_text(v_hand) h WHERE h.x::int = v_card);
    FOR v_j IN 1..(v_hand_cnt - v_play_cnt) LOOP
      v_new_hand := v_new_hand || to_jsonb(v_card);
    END LOOP;
  END LOOP;
  v_state := jsonb_set(v_state, ARRAY['hands', v_seat::text], v_new_hand);

  -- 炸弹/火箭翻倍
  IF v_cls->>'type' IN ('bomb','rocket') THEN
    v_state := jsonb_set(v_state, ARRAY['multiplier'], to_jsonb((v_state->>'multiplier')::int * 2));
  END IF;

  -- 记录本轮出牌
  v_state := jsonb_set(v_state, ARRAY['last_play'],
    v_cls || jsonb_build_object('seat', v_seat, 'cards', p_cards));
  v_state := jsonb_set(v_state, ARRAY['pass_count'], to_jsonb(0));

  -- 胜负判定
  IF jsonb_array_length(v_new_hand) = 0 THEN
    v_is_landlord := ((v_state->>'landlord')::int = v_seat);
    v_winner := CASE WHEN v_is_landlord THEN 'landlord' ELSE 'farmers' END;
    v_state := jsonb_set(v_state, ARRAY['ended'],
      jsonb_build_object('winner', v_winner, 'winner_seat', v_seat));
    UPDATE game_rooms SET status = 'ended', game_state = v_state, updated_at = now()
    WHERE id = v_room.id RETURNING * INTO v_room;
    RETURN jsonb_build_object(
      'room_code', v_room.room_code, 'max_players', v_room.max_players,
      'players', v_room.players, 'status', v_room.status,
      'game_state', v_room.game_state, 'updated_at', v_room.updated_at
    );
  END IF;

  -- 轮转
  v_next := _next_seat(v_state, v_seat, v_room.players);
  v_state := jsonb_set(v_state, ARRAY['current_seat'], to_jsonb(v_next));
  v_state := jsonb_set(v_state, ARRAY['turn_deadline'],
    to_jsonb(to_char(now() + interval '20 seconds', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')));

  UPDATE game_rooms SET game_state = v_state, updated_at = now() WHERE id = v_room.id
  RETURNING * INTO v_room;
  RETURN jsonb_build_object(
    'room_code', v_room.room_code, 'max_players', v_room.max_players,
    'players', v_room.players, 'status', v_room.status,
    'game_state', v_room.game_state, 'updated_at', v_room.updated_at
  );
END $$;
GRANT EXECUTE ON FUNCTION play_cards(TEXT, TEXT, jsonb) TO anon, authenticated;

-- 过牌（不要）
CREATE OR REPLACE FUNCTION pass_turn(p_room_code TEXT, p_nickname TEXT)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_room game_rooms%ROWTYPE;
  v_state jsonb;
  v_seat INT := -1;
  v_cur INT;
  v_n INT;
  v_i INT;
  v_last jsonb;
  v_next INT;
BEGIN
  SELECT * INTO v_room FROM game_rooms WHERE upper(room_code) = upper(p_room_code) FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION '房间不存在'; END IF;
  IF v_room.status <> 'playing' THEN RAISE EXCEPTION '游戏不在进行中'; END IF;
  v_state := v_room.game_state;
  IF v_state->>'phase' <> 'playing' THEN RAISE EXCEPTION '叫地主尚未结束'; END IF;
  v_n := jsonb_array_length(v_room.players);
  FOR v_i IN 0..(v_n - 1) LOOP
    IF v_room.players->v_i->>'nickname' = p_nickname THEN v_seat := v_i; END IF;
  END LOOP;
  IF v_seat < 0 THEN RAISE EXCEPTION '你不在本房间'; END IF;
  v_cur := (v_state->>'current_seat')::int;
  IF v_seat <> v_cur THEN RAISE EXCEPTION '还没轮到你'; END IF;
  v_last := v_state->'last_play';
  -- 自由出牌局面（无上一手 或 上一手是自己）不允许"不要"
  IF v_last IS NULL OR v_last = 'null'::jsonb OR (v_last->>'seat')::int = v_seat THEN
    RAISE EXCEPTION '必须出牌';
  END IF;
  v_state := jsonb_set(v_state, ARRAY['pass_count'], to_jsonb((v_state->>'pass_count')::int + 1));
  v_next := _next_seat(v_state, v_seat, v_room.players);
  -- 若下一家就是上一手出牌者（其他人都 pass），清空 last_play 使其自由出牌
  IF (v_last->>'seat')::int = v_next THEN
    v_state := jsonb_set(v_state, ARRAY['last_play'], 'null'::jsonb);
    v_state := jsonb_set(v_state, ARRAY['pass_count'], to_jsonb(0));
  END IF;
  v_state := jsonb_set(v_state, ARRAY['current_seat'], to_jsonb(v_next));
  v_state := jsonb_set(v_state, ARRAY['turn_deadline'],
    to_jsonb(to_char(now() + interval '20 seconds', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')));
  UPDATE game_rooms SET game_state = v_state, updated_at = now() WHERE id = v_room.id
  RETURNING * INTO v_room;
  RETURN jsonb_build_object(
    'room_code', v_room.room_code, 'max_players', v_room.max_players,
    'players', v_room.players, 'status', v_room.status,
    'game_state', v_room.game_state, 'updated_at', v_room.updated_at
  );
END $$;
GRANT EXECUTE ON FUNCTION pass_turn(TEXT, TEXT) TO anon, authenticated;

-- 超时自动过牌（前端倒计时到 0 时调用；若必须出牌则自动出最小单张）
CREATE OR REPLACE FUNCTION auto_pass(p_room_code TEXT)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_room game_rooms%ROWTYPE;
  v_state jsonb;
  v_cur INT;
  v_n INT;
  v_i INT;
  v_last jsonb;
  v_hand jsonb;
  v_min_card INT;
  v_cards jsonb;
BEGIN
  SELECT * INTO v_room FROM game_rooms WHERE upper(room_code) = upper(p_room_code) FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION '房间不存在'; END IF;
  IF v_room.status <> 'playing' THEN RETURN get_room(p_room_code); END IF;
  v_state := v_room.game_state;
  IF v_state->>'phase' <> 'playing' THEN RETURN get_room(p_room_code); END IF;
  v_cur := (v_state->>'current_seat')::int;
  v_n := jsonb_array_length(v_room.players);
  v_last := v_state->'last_play';
  -- 可以过牌的情况
  IF v_last IS NOT NULL AND v_last <> 'null'::jsonb AND (v_last->>'seat')::int <> v_cur THEN
    RETURN pass_turn(p_room_code, v_room.players->v_cur->>'nickname');
  END IF;
  -- 必须出牌：自动出最小单张
  v_hand := v_state->'hands'->v_cur::text;
  SELECT min(x::int) INTO v_min_card FROM jsonb_array_elements_text(v_hand) AS x;
  v_cards := jsonb_build_array(v_min_card);
  RETURN play_cards(p_room_code, v_room.players->v_cur->>'nickname', v_cards);
END $$;
GRANT EXECUTE ON FUNCTION auto_pass(TEXT) TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5) 文字冒险 RPC
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION list_stories()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_rows jsonb;
BEGIN
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'title', s.title,
    'created_at', s.created_at, 'node_count', (SELECT count(*) FROM story_nodes n WHERE n.story_id = s.id))
    ORDER BY s.id), '[]'::jsonb)
  INTO v_rows FROM stories s;
  RETURN v_rows;
END $$;
GRANT EXECUTE ON FUNCTION list_stories() TO anon, authenticated;

CREATE OR REPLACE FUNCTION get_story_node(p_story_id BIGINT, p_node_key TEXT)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_node story_nodes%ROWTYPE;
BEGIN
  SELECT * INTO v_node FROM story_nodes
  WHERE story_id = p_story_id AND node_key = p_node_key;
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN jsonb_build_object(
    'story_id', v_node.story_id, 'node_key', v_node.node_key,
    'content', v_node.content, 'option_a', v_node.option_a,
    'target_a', v_node.target_a, 'option_b', v_node.option_b,
    'target_b', v_node.target_b,
    'is_end', (v_node.target_a IS NULL AND v_node.target_b IS NULL)
  );
END $$;
GRANT EXECUTE ON FUNCTION get_story_node(BIGINT, TEXT) TO anon, authenticated;

-- 存档（设备昵称绑定）
CREATE OR REPLACE FUNCTION save_story_progress(p_nickname TEXT, p_story_id BIGINT, p_node_key TEXT)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_nickname IS NULL OR length(trim(p_nickname)) = 0 THEN
    RAISE EXCEPTION '昵称不能为空';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM story_nodes WHERE story_id = p_story_id AND node_key = p_node_key) THEN
    RAISE EXCEPTION '目标节点不存在';
  END IF;
  INSERT INTO story_progress (nickname, story_id, current_node, updated_at)
  VALUES (p_nickname, p_story_id, p_node_key, now())
  ON CONFLICT (nickname, story_id)
  DO UPDATE SET current_node = excluded.current_node, updated_at = now();
  RETURN jsonb_build_object('ok', true, 'nickname', p_nickname,
    'story_id', p_story_id, 'current_node', p_node_key);
END $$;
GRANT EXECUTE ON FUNCTION save_story_progress(TEXT, BIGINT, TEXT) TO anon, authenticated;

CREATE OR REPLACE FUNCTION get_story_progress(p_nickname TEXT, p_story_id BIGINT)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_row story_progress%ROWTYPE;
BEGIN
  SELECT * INTO v_row FROM story_progress
  WHERE nickname = p_nickname AND story_id = p_story_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN jsonb_build_object('nickname', v_row.nickname, 'story_id', v_row.story_id,
    'current_node', v_row.current_node, 'updated_at', v_row.updated_at);
END $$;
GRANT EXECUTE ON FUNCTION get_story_progress(TEXT, BIGINT) TO anon, authenticated;

-- 编辑器 RPC（仅管理员使用；由前端先做 is_admin 校验）
CREATE OR REPLACE FUNCTION create_story(p_title TEXT)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_id BIGINT;
BEGIN
  IF p_title IS NULL OR length(trim(p_title)) = 0 THEN
    RAISE EXCEPTION '标题不能为空';
  END IF;
  INSERT INTO stories (title) VALUES (trim(p_title)) RETURNING id INTO v_id;
  -- 默认起始节点
  INSERT INTO story_nodes (story_id, node_key, content, option_a, target_a, option_b, target_b, pos_x, pos_y)
  VALUES (v_id, 'start', '（新故事的开始，请编辑这里的内容）', '继续', 'start', NULL, NULL, 0, 0);
  RETURN jsonb_build_object('id', v_id, 'title', trim(p_title));
END $$;
GRANT EXECUTE ON FUNCTION create_story(TEXT) TO anon, authenticated;

CREATE OR REPLACE FUNCTION get_story_nodes(p_story_id BIGINT)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_rows jsonb;
BEGIN
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'node_key', n.node_key,
    'content', n.content, 'option_a', n.option_a, 'target_a', n.target_a,
    'option_b', n.option_b, 'target_b', n.target_b,
    'pos_x', n.pos_x, 'pos_y', n.pos_y) ORDER BY n.id), '[]'::jsonb)
  INTO v_rows FROM story_nodes n WHERE n.story_id = p_story_id;
  RETURN v_rows;
END $$;
GRANT EXECUTE ON FUNCTION get_story_nodes(BIGINT) TO anon, authenticated;

CREATE OR REPLACE FUNCTION save_story_node(p_story_id BIGINT, p_node_key TEXT, p_content TEXT,
  p_option_a TEXT, p_target_a TEXT, p_option_b TEXT, p_target_b TEXT,
  p_pos_x DOUBLE PRECISION DEFAULT 0, p_pos_y DOUBLE PRECISION DEFAULT 0)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_content IS NULL OR length(trim(p_content)) = 0 THEN
    RAISE EXCEPTION '节点内容不能为空';
  END IF;
  IF p_node_key IS NULL OR length(trim(p_node_key)) = 0 THEN
    RAISE EXCEPTION '节点 key 不能为空';
  END IF;
  INSERT INTO story_nodes (story_id, node_key, content, option_a, target_a, option_b, target_b, pos_x, pos_y)
  VALUES (p_story_id, p_node_key, p_content, p_option_a, p_target_a, p_option_b, p_target_b,
          coalesce(p_pos_x, 0), coalesce(p_pos_y, 0))
  ON CONFLICT (story_id, node_key)
  DO UPDATE SET content = excluded.content,
    option_a = excluded.option_a, target_a = excluded.target_a,
    option_b = excluded.option_b, target_b = excluded.target_b,
    pos_x = excluded.pos_x, pos_y = excluded.pos_y;
  RETURN jsonb_build_object('ok', true, 'story_id', p_story_id, 'node_key', p_node_key);
END $$;
GRANT EXECUTE ON FUNCTION save_story_node(BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION) TO anon, authenticated;

CREATE OR REPLACE FUNCTION delete_story_node(p_story_id BIGINT, p_node_key TEXT)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  DELETE FROM story_nodes WHERE story_id = p_story_id AND node_key = p_node_key;
  -- 引用该节点的选项置空，避免断链
  UPDATE story_nodes SET target_a = NULL WHERE story_id = p_story_id AND target_a = p_node_key;
  UPDATE story_nodes SET target_b = NULL WHERE story_id = p_story_id AND target_b = p_node_key;
  RETURN jsonb_build_object('ok', true, 'deleted_key', p_node_key);
END $$;
GRANT EXECUTE ON FUNCTION delete_story_node(BIGINT, TEXT) TO anon, authenticated;

CREATE OR REPLACE FUNCTION delete_story(p_story_id BIGINT)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  DELETE FROM story_nodes WHERE story_id = p_story_id;
  DELETE FROM story_progress WHERE story_id = p_story_id;
  DELETE FROM stories WHERE id = p_story_id;
  RETURN jsonb_build_object('ok', true);
END $$;
GRANT EXECUTE ON FUNCTION delete_story(BIGINT) TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6) 种子数据
-- ---------------------------------------------------------------------------

-- 默认管理员（测试用）：登录昵称"admin"即可进入管理后台
INSERT INTO admins (nickname) VALUES ('admin')
ON CONFLICT (nickname) DO NOTHING;

-- 示例文字冒险《勇者斗恶龙》
INSERT INTO stories (id, title) OVERRIDING SYSTEM VALUE VALUES (1, '勇者斗恶龙') ON CONFLICT DO NOTHING;
INSERT INTO story_nodes (story_id, node_key, content, option_a, target_a, option_b, target_b, pos_x, pos_y) VALUES
(1, 'start', '你是一名年轻的勇者，站在巨龙山谷的入口。传说恶龙盘踞在山谷深处的古堡中，掳走了王国的小公主。你要如何开始你的冒险？', '小心潜入山谷', 'forest', '大张旗鼓杀进去', 'gate', 40, 120),
(1, 'forest', '你在茂密的森林中潜行，忽然发现一个受伤的老猎人。他愿意告诉你恶龙的弱点，作为回报，他希望你能带给他一株月光草。', '接受猎人的请求', 'moonlight', '婉拒并独自前行', 'cave', 250, 120),
(1, 'gate', '你挥舞着长剑冲向古堡大门，惊动了恶龙的守卫石像鬼。一场恶战即将开始！', '迎战石像鬼', 'fight', '退回森林隐藏', 'forest', 250, 320),
(1, 'moonlight', '你在月光下的湖边找到了月光草。老猎人告诉你：恶龙的护甲在月光下会变得脆弱，用月光草炼制的药剂可以破除它的防御。', '炼制月光药剂', 'cave', '直接去找恶龙', 'cave', 460, 120),
(1, 'cave', '你来到古堡深处的龙穴，恶龙正守护着沉睡的公主。你手中握着月光药剂，心跳如鼓。', '使用月光药剂攻击', 'victory', '与恶龙谈判', 'talk', 460, 320),
(1, 'fight', '你与石像鬼展开激战。经过一番苦战，你终于击败了它们，但也受了重伤。你踉跄着走进古堡，面对最后的决战。', '继续前进', 'cave', '先疗伤再说', 'forest', 460, 520),
(1, 'talk', '你试图与恶龙谈判。恶龙发出低沉的笑声：『勇士，公主其实是我自愿留下的——她正在为我编写诗歌集。』', '相信恶龙，转身离开', 'ending_talk', '不信，拔剑相向', 'cave', 460, 620),
(1, 'victory', '你掷出月光药剂，恶龙的护甲在月光下碎裂。你一剑刺穿它的心脏，救出了公主。国王为你加冕，你成为王国最伟大的勇者！【结局：屠龙英雄】', NULL, NULL, NULL, NULL, 500, 500),
(1, 'ending_talk', '你转身离开，却听到公主的声音：『别走！他说谎！』你回头，看见公主挣脱束缚，手中握着恶龙偷来的圣剑……原来真正的恶龙是公主的叔叔，他篡位后躲在这里。你和公主联手击败了他，王国恢复了和平。【结局：真相大白】', NULL, NULL, NULL, NULL, 500, 200)
ON CONFLICT (story_id, node_key) DO NOTHING;
