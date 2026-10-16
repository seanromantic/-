// 房间系统（所有桌游共用）
const Room = {
  client() {
    return supabase.createClient(CONFIG.SUPABASE_URL, CONFIG.SUPABASE_KEY);
  },

  async create(roomCode, options) {
    var c = this.client();
    var res = await c.from('rooms').select('*').eq('room_code', roomCode);
    if (res.data && res.data.length > 0) return { error: '房间号已存在' };
    var ins = await c.from('rooms').insert({
      room_code: roomCode,
      players: [],
      status: 'waiting',
      game_state: options || {}
    });
    return ins.error ? { error: ins.error.message } : { ok: true };
  },

  async join(roomCode, nickname, maxPlayers) {
    var c = this.client();
    var res = await c.from('rooms').select('*').eq('room_code', roomCode);
    if (res.error || !res.data || res.data.length === 0) return { error: '房间不存在' };
    var room = res.data[0];
    var players = room.players || [];
    if (players.indexOf(nickname) !== -1) return { ok: true };
    if (maxPlayers && players.length >= maxPlayers) return { error: '房间已满' };
    players.push(nickname);
    var upd = await c.from('rooms').update({ players: players }).eq('room_code', roomCode);
    return upd.error ? { error: upd.error.message } : { ok: true };
  },

  async leave(roomCode, nickname) {
    var c = this.client();
    var res = await c.from('rooms').select('*').eq('room_code', roomCode);
    if (res.error || !res.data || res.data.length === 0) return;
    var room = res.data[0];
    var players = (room.players || []).filter(function (n) { return n !== nickname; });
    await c.from('rooms').update({ players: players }).eq('room_code', roomCode);
  },

  async get(roomCode) {
    var c = this.client();
    var res = await c.from('rooms').select('*').eq('room_code', roomCode);
    return (res.data && res.data[0]) || null;
  },

  async updateState(roomCode, gameState, status) {
    var c = this.client();
    var payload = { game_state: gameState };
    if (status) payload.status = status;
    await c.from('rooms').update(payload).eq('room_code', roomCode);
  }
};
