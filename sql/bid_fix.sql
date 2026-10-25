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
  v_hand jsonb;
  v_landlord INT;
  v_retry INT;
BEGIN
  SELECT * INTO v_room FROM game_rooms WHERE upper(room_code) = upper(p_room_code) FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION '房间不存在'; END IF;
  IF v_room.status <> 'playing' THEN RAISE EXCEPTION '游戏不在进行中'; END IF;
  v_state := v_room.game_state;
  IF v_state->>'phase' <> 'bid' THEN RAISE EXCEPTION '不在叫地主阶段'; END IF;

  v_n := jsonb_array_length(v_room.players);
  FOR v_i IN 0..(v_n - 1) LOOP
    IF v_room.players->v_i->>'nickname' = p_nickname THEN v_seat := v_i; END IF;
  END LOOP;
  IF v_seat < 0 THEN RAISE EXCEPTION '你不在本房间'; END IF;
  v_cur := (v_state->>'current_seat')::int;
  IF v_seat <> v_cur THEN RAISE EXCEPTION '还没轮到你叫地主'; END IF;
  IF p_points NOT IN (0,1,2,3) THEN RAISE EXCEPTION '叫分必须是 0/1/2/3'; END IF;

  -- 记录叫分历史
  v_state := jsonb_set(v_state, ARRAY['bid_history'],
    (v_state->'bid_history') || jsonb_build_array(jsonb_build_object('seat', v_seat, 'points', p_points)));

  -- 更新最高分
  v_high_seat := (v_state->'bid_high'->>'seat')::int;
  v_high_pts := COALESCE((v_state->'bid_high'->>'points')::int, 0);
  IF v_high_seat IS NULL OR p_points > v_high_pts THEN
    v_state := jsonb_set(v_state, ARRAY['bid_high'],
      jsonb_build_object('seat', v_seat, 'points', p_points));
  END IF;

  v_state := jsonb_set(v_state, ARRAY['bid_round'], to_jsonb(((v_state->>'bid_round')::int) + 1));

  -- 所有人都叫过了
  IF (v_state->>'bid_round')::int >= v_n THEN
    v_high_seat := (v_state->'bid_high'->>'seat')::int;
    v_high_pts := COALESCE((v_state->'bid_high'->>'points')::int, 0);

    IF v_high_seat IS NOT NULL AND v_high_pts > 0 THEN
      -- 定地主，底牌并入手牌
      v_landlord := v_high_seat;
      v_hand := jsonb_extract_path(v_state, 'hands', v_landlord::text) || jsonb_extract_path(v_state, 'base');
      v_state := jsonb_set(v_state, ARRAY['hands', v_landlord::text], v_hand);
      v_state := jsonb_set(v_state, ARRAY['landlord'], to_jsonb(v_landlord));
      v_state := jsonb_set(v_state, ARRAY['multiplier'], to_jsonb(greatest(v_high_pts, 1)));
      v_state := jsonb_set(v_state, ARRAY['phase'], '"playing"'::jsonb);
      v_state := jsonb_set(v_state, ARRAY['current_seat'], to_jsonb(v_landlord));
      v_state := jsonb_set(v_state, ARRAY['pass_count'], to_jsonb(0));
      v_state := jsonb_set(v_state, ARRAY['last_play'], 'null'::jsonb);
      v_state := jsonb_set(v_state, ARRAY['turn_deadline'],
        to_jsonb(to_char(now() + interval '20 seconds', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')));
    ELSE
      -- 全部不叫，重新发牌
      v_retry := (v_state->>'bid_retry')::int + 1;
      IF v_retry >= 5 THEN
        -- 5次都不叫，强制随机地主
        v_landlord := floor(random() * v_n)::int;
        v_hand := jsonb_extract_path(v_state, 'hands', v_landlord::text) || jsonb_extract_path(v_state, 'base');
        v_state := jsonb_set(v_state, ARRAY['hands', v_landlord::text], v_hand);
        v_state := jsonb_set(v_state, ARRAY['landlord'], to_jsonb(v_landlord));
        v_state := jsonb_set(v_state, ARRAY['phase'], '"playing"'::jsonb);
        v_state := jsonb_set(v_state, ARRAY['current_seat'], to_jsonb(v_landlord));
        v_state := jsonb_set(v_state, ARRAY['pass_count'], to_jsonb(0));
        v_state := jsonb_set(v_state, ARRAY['last_play'], 'null'::jsonb);
      ELSE
        -- 重新洗牌发牌
        v_state := jsonb_set(v_state, ARRAY['bid_round'], to_jsonb(0));
        v_state := jsonb_set(v_state, ARRAY['bid_high'], jsonb_build_object('seat', NULL, 'points', 0));
        v_state := jsonb_set(v_state, ARRAY['bid_history'], '[]'::jsonb);
        v_state := jsonb_set(v_state, ARRAY['bid_retry'], to_jsonb(v_retry));
      END IF;
    END IF;
  ELSE
    -- 换下一个人叫
    v_state := jsonb_set(v_state, ARRAY['current_seat'], to_jsonb((v_seat + 1) % v_n));
  END IF;

  UPDATE game_rooms SET game_state = v_state, updated_at = now()
  WHERE id = v_room.id RETURNING * INTO v_room;

  RETURN jsonb_build_object(
    'room_code', v_room.room_code, 'max_players', v_room.max_players,
    'players', v_room.players, 'status', v_room.status,
    'game_state', v_room.game_state, 'updated_at', v_room.updated_at
  );
END $$;
