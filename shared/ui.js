// UI 工具
const UI = {
  // 渲染头像
  renderAvatar(el, size) {
    if (!el) return;
    el.className = 'avatar avatar-' + (size || 'md');
    el.innerText = User.getAvatarText();
    el.style.background = User.getAvatarColor();
  },

  // 渲染游戏卡片
  renderGameCard(game, index) {
    var card = document.createElement('div');
    card.className = 'game-card anim-up anim-delay-' + Math.min(index + 1, 5);
    if (!game.online) card.classList.add('disabled');
    card.innerHTML =
      '<span class="hex">' + game.icon + '</span>' +
      '<span class="label">' + game.name + (game.online ? '' : ' · 即将上线') + '</span>';
    if (game.online) {
      card.onclick = function () { location.href = game.path; };
    }
    return card;
  },

  // 判断玩家是否在线（在 players 列表里 = 在线）
  isOnline(players, nickname) {
    return players && players.indexOf(nickname) !== -1;
  },

  // 渲染一个玩家座位
  renderSeat(playerName, options) {
    var opts = options || {};
    var seat = document.createElement('div');
    seat.className = 'player-seat ' + (opts.position || '');

    var wrap = document.createElement('div');
    wrap.className = 'avatar-wrap';

    var avatar = document.createElement('div');
    avatar.className = 'avatar avatar-md';
    avatar.innerText = playerName ? playerName.charAt(0).toUpperCase() : '?';
    avatar.style.background = opts.color || this._colorFromName(playerName);

    wrap.appendChild(avatar);

    // 在线小圆点
    var dot = document.createElement('span');
    dot.className = 'status-dot ' + (opts.online ? 'online' : 'offline');
    wrap.appendChild(dot);

    // 房主标记
    if (opts.isLandlord) {
      var tag = document.createElement('span');
      tag.className = 'landlord-tag';
      tag.innerText = '地主';
      wrap.appendChild(tag);
    }

    seat.appendChild(wrap);

    if (opts.showName !== false) {
      var nameEl = document.createElement('div');
      nameEl.className = 'player-name';
      nameEl.innerText = playerName || '等待加入';
      seat.appendChild(nameEl);
    }

    if (typeof opts.cardCount === 'number') {
      var cnt = document.createElement('div');
      cnt.className = 'card-count';
      cnt.innerText = opts.cardCount + ' 张';
      seat.appendChild(cnt);
    }

    if (opts.active) seat.classList.add('active');

    return seat;
  },

  // 内部：从名字生成颜色
  _colorFromName(n) {
    var name = n || '?';
    var colors = ['#5b8cff', '#8e6bff', '#f472b6', '#34d399', '#fbbf24', '#f87171', '#60a5fa'];
    var code = 0;
    for (var i = 0; i < name.length; i++) code += name.charCodeAt(i);
    return colors[code % colors.length];
  },


// 渲染整个牌桌
  renderTable(container, players, myName, gameState, playerCount) {
    var self = this;
    container.innerHTML = '';
    var myIndex = players.indexOf(myName);
    if (myIndex === -1) myIndex = 0;

    var positions = [];
    if (playerCount === 3) positions = ['seat-left', 'seat-right'];
    else positions = ['seat-left', 'seat-top', 'seat-right'];

    var others = [];
    for (var i = 1; i < playerCount; i++) {
      others.push((myIndex + i) % playerCount);
    }

    // 先查所有玩家的等级
    var names = players.filter(function (n) { return !!n; });
    var levelMap = {};
    if (names.length > 0 && typeof supabase !== 'undefined') {
      try {
        var client = supabase.createClient(CONFIG.SUPABASE_URL, CONFIG.SUPABASE_KEY);
        client.from('users').select('nickname, total_days, real_name').in('nickname', names).then(function (res) {
          if (res.data) {
            res.data.forEach(function (u) {
              levelMap[u.nickname] = {
                level: u.total_days || 1,
                isAdmin: u.real_name === CONFIG.ADMIN_NAME
              };
            });
          }
          // 拿到等级后再渲染
          self._renderSeats(container, players, myName, gameState, playerCount, myIndex, positions, others, levelMap);
        });
        return;
      } catch (e) {}
    }

    // 查不到就直接渲染（无等级）
    self._renderSeats(container, players, myName, gameState, playerCount, myIndex, positions, others, {});
  },// 内部：渲染座位
  _renderSeats(container, players, myName, gameState, playerCount, myIndex, positions, others, levelMap) {
    var self = this;

    others.forEach(function (idx, k) {
      var name = players[idx] || '等待加入';
      var online = self.isOnline(players, players[idx]);
      var info = levelMap[name] || {};
      var seat = self.renderSeat(name, {
        position: positions[k],
        online: online,
        cardCount: gameState && gameState.hands && gameState.hands[idx] ? gameState.hands[idx].length : 0,
        active: gameState && gameState.turn === idx,
        isLandlord: gameState && gameState.landlord === idx,
        crownIndex: info.level ? Math.min(Math.floor((info.level - 1) / 99) + 1, 10) : null,
        level: info.level || 1,
        isAdminCrown: info.isAdmin
      });
      container.appendChild(seat);
    });

    var meInfo = levelMap[myName] || {};
    var meSeat = self.renderSeat(myName, {
      position: 'seat-bottom',
      online: true,
      cardCount: gameState && gameState.hands && gameState.hands[myIndex] ? gameState.hands[myIndex].length : 0,
      active: gameState && gameState.turn === myIndex,
      isLandlord: gameState && gameState.landlord === myIndex,
      crownIndex: User.getCrownIndex(),
      level: User.getLevel(),
      isAdminCrown: User.isAdminCrown()
    });
    container.appendChild(meSeat);
  },

    // 找出自己在列表中的索引
    var myIndex = players.indexOf(myName);
    if (myIndex === -1) myIndex = 0;

    // 计算其他玩家的位置
    // 3人局：自己下方、左边、右边
    // 4人局：自己下方、左、右、对面
    var positions = [];
    if (playerCount === 3) {
      positions = ['seat-left', 'seat-right'];
    } else {
      positions = ['seat-left', 'seat-top', 'seat-right'];
    }

    var others = [];
    for (var i = 1; i < playerCount; i++) {
      others.push((myIndex + i) % playerCount);
    }

    // 渲染其他玩家
    others.forEach(function (idx, k) {
      var name = players[idx] || '等待加入';
      var online = UI.isOnline(players, players[idx]);
      var seat = UI.renderSeat(name, {
        position: positions[k],
        online: online,
        cardCount: gameState && gameState.hands && gameState.hands[idx] ? gameState.hands[idx].length : 0,
        active: gameState && gameState.turn === idx,
        isLandlord: gameState && gameState.landlord === idx
      });
      container.appendChild(seat);
    });

    // 渲染自己
    var meSeat = UI.renderSeat(myName, {
      position: 'seat-bottom',
      online: true,
      cardCount: gameState && gameState.hands && gameState.hands[myIndex] ? gameState.hands[myIndex].length : 0,
      active: gameState && gameState.turn === myIndex,
      isLandlord: gameState && gameState.landlord === myIndex
    });
    container.appendChild(meSeat);
  },

  // 发牌动画：从屏幕上方一张一张飞到指定位置
  // totalCards: 总张数, duration: 总时长（毫秒）
  dealAnimation(totalCards, duration, callback) {
    var layer = document.createElement('div');
    layer.className = 'deal-layer';
    document.body.appendChild(layer);

    var perCard = duration / totalCards;
    var i = 0;

    function next() {
      if (i >= totalCards) {
        setTimeout(function () {
          layer.remove();
          if (callback) callback();
        }, 400);
        return;
      }
      var card = document.createElement('div');
      card.className = 'deal-card';
      card.style.left = '50%';
      card.style.top = '-60px';
      card.style.transform = 'translateX(-50%)';
      layer.appendChild(card);

      // 随机飞到屏幕三个方向之一
      var targets = [
        { x: '15%', y: '40%' },
        { x: '85%', y: '40%' },
        { x: '50%', y: '75%' }
      ];
      var t = targets[i % targets.length];
      setTimeout(function () {
        card.style
