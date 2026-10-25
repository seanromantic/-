#!/bin/bash
# 斗地主叫分流程完整测试脚本

SUPABASE_URL="https://djvsugbstenltenktpwv.supabase.co"
SUPABASE_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImRqdnN1Z2JzdGVubHRlbmt0cHd2Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTE2OTI0MDcsImV4cCI6MjEwNzI2ODQwN30.XMBE7NCridZ34BG7LyRiHQRZP0SkVI209uQhqSgcIAs"

echo "=== 斗地主叫分流程完整测试 ==="

P1="test_user1"
P2="test_user2"
P3="test_user3"

echo ""
echo "1. 玩家1创建房间"
RESULT=$(curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/create_room" \
  -H "apikey: $SUPABASE_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"p_nickname\": \"$P1\", \"p_max_players\": 3}")
ROOM_CODE=$(echo "$RESULT" | jq -r '.room_code')
echo "   房间号: $ROOM_CODE"

echo ""
echo "2. 玩家2加入房间"
curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/join_room" \
  -H "apikey: $SUPABASE_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"p_room_code\": \"$ROOM_CODE\", \"p_nickname\": \"$P2\"}" | jq -r '.role'

echo ""
echo "3. 玩家3加入房间"
curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/join_room" \
  -H "apikey: $SUPABASE_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"p_room_code\": \"$ROOM_CODE\", \"p_nickname\": \"$P3\"}" | jq -r '.role'

echo ""
echo "4. 玩家1开始游戏"
curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/start_game" \
  -H "apikey: $SUPABASE_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"p_room_code\": \"$ROOM_CODE\", \"p_nickname\": \"$P1\"}" | jq -r '   phase: \(.game_state.phase), current_seat: \(.game_state.current_seat)'

echo ""
echo "5. 玩家1叫 1 分"
curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/bid" \
  -H "apikey: $SUPABASE_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"p_room_code\": \"$ROOM_CODE\", \"p_nickname\": \"$P1\", \"p_points\": 1}" | jq -r '   phase: \(.game_state.phase), current_seat: \(.game_state.current_seat), bid_high: seat=\(.game_state.bid_high.seat) points=\(.game_state.bid_high.points)'

echo ""
echo "6. 玩家2叫 2 分"
curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/bid" \
  -H "apikey: $SUPABASE_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"p_room_code\": \"$ROOM_CODE\", \"p_nickname\": \"$P2\", \"p_points\": 2}" | jq -r '   phase: \(.game_state.phase), current_seat: \(.game_state.current_seat), bid_high: seat=\(.game_state.bid_high.seat) points=\(.game_state.bid_high.points)'

echo ""
echo "7. 玩家3叫 3 分（关键测试点）"
RESULT=$(curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/bid" \
  -H "apikey: $SUPABASE_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"p_room_code\": \"$ROOM_CODE\", \"p_nickname\": \"$P3\", \"p_points\": 3}")
echo "$RESULT" | jq -r '   phase: \(.game_state.phase), landlord: \(.game_state.landlord), multiplier: \(.game_state.multiplier)'

PHASE=$(echo "$RESULT" | jq -r '.game_state.phase')
LANDLORD=$(echo "$RESULT" | jq -r '.game_state.landlord')
MULTIPLIER=$(echo "$RESULT" | jq -r '.game_state.multiplier')

echo ""
echo "=== 测试结果 ==="
if [ "$PHASE" = "playing" ] && [ "$LANDLORD" = "2" ] && [ "$MULTIPLIER" = "3" ]; then
  echo "✅ 测试通过！叫分流程正常，地主确定为玩家3，倍数3"
else
  echo "❌ 测试失败！"
fi
