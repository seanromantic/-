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
       > (SELECT count(*) FROM jsonb_array_elements_text(v_hand) AS h(x) WHERE h.x::int = v_cards[v_i]) THEN
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
    v_hand_cnt := (SELECT count(*) FROM jsonb_array_elements_text(v_hand) AS h(x) WHERE h.x::int = v_card);
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
