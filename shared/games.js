// 游戏注册表：加新游戏只改这里
const GAMES = [
  {
    id: 'chat',
    name: '聊天室',
    icon: '💬',
    path: 'games/chat.html',
    players: 0,
    type: 'chat',
    online: true
  },
  {
    id: 'doudizhu',
    name: '斗地主',
    icon: '🃏',
    path: 'games/doudizhu.html',
    players: 3,
    type: 'card',
    online: true
  },
  {
    id: 'gomoku',
    name: '五子棋',
    icon: '⭕',
    path: 'games/gomoku.html',
    players: 2,
    type: 'board',
    online: false
  },
  {
    id: 'chess',
    name: '象棋',
    icon: '♟️',
    path: 'games/chess.html',
    players: 2,
    type: 'board',
    online: false
  }
];
