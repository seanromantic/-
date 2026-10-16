// 用户模块
const User = {
  get() {
    try {
      var s = localStorage.getItem('samarra_user');
      return s ? JSON.parse(s) : null;
    } catch (e) { return null; }
  },
  isLoggedIn() {
    var u = this.get();
    return !!(u && u.realName && u.nickname);
  },
  requireLogin() {
    if (!this.isLoggedIn()) {
      location.replace('login.html');
      return false;
    }
    return true;
  },
  getNickname() {
    var u = this.get();
    return u ? u.nickname : '';
  },
  getRealName() {
    var u = this.get();
    return u ? u.realName : '';
  },
  isAdmin() {
    return this.getRealName() === CONFIG.ADMIN_NAME;
  },
  getAvatarText() {
    var n = this.getNickname();
    return n ? n.charAt(0).toUpperCase() : '?';
  },
  getAvatarColor() {
    var n = this.getNickname() || '?';
    var colors = ['#5b8cff', '#8e6bff', '#f472b6', '#34d399', '#fbbf24', '#f87171', '#60a5fa'];
    var code = 0;
    for (var i = 0; i < n.length; i++) code += n.charCodeAt(i);
    return colors[code % colors.length];
  },

  // 获取今天的日期字符串 YYYY-MM-DD
  _todayStr() {
    var d = new Date();
    var m = (d.getMonth() + 1).toString().padStart(2, '0');
    var day = d.getDate().toString().padStart(2, '0');
    return d.getFullYear() + '-' + m + '-' + day;
  },

  // 每天首次打开时调用：当天没登录过就 +1 天
  checkDailyLogin() {
    var u = this.get();
    if (!u) return;
    var today = this._todayStr();
    if (u.lastLoginDate === today) return;  // 今天已登录过

    u.totalDays = (u.totalDays || 0) + 1;
    u.lastLoginDate = today;
    try {
      localStorage.setItem('samarra_user', JSON.stringify(u));
    } catch (e) {}

    // 同步到数据库
    if (typeof supabase !== 'undefined' && CONFIG) {
      try {
        var client = supabase.createClient(CONFIG.SUPABASE_URL, CONFIG.SUPABASE_KEY);
        client.from('users').update({ total_days: u.totalDays }).eq('real_name', u.realName);
      } catch (e) {}
    }
  },

  // 累计登录天数 = 等级
  getLevel() {
    if (this.isAdmin()) return 999;
    var u = this.get();
    if (!u) return 1;
    return Math.min(u.totalDays || 1, 990);
  },

  // 皇冠编号 1~10
  getCrownIndex() {
    if (this.isAdmin()) return 10;
    var lv = this.getLevel();
    var idx = Math.floor((lv - 1) / 99) + 1;
    return Math.min(idx, 10);
  },

  isAdminCrown() {
    return this.isAdmin();
  },

  setNickname(nickname) {
    var u = this.get();
    if (!u) return false;
    u.nickname = nickname;
    try {
      localStorage.setItem('samarra_user', JSON.stringify(u));
      return true;
    } catch (e) { return false; }
  },

  login(realName, nickname, totalDays) {
    var data = {
      realName: realName,
      nickname: nickname,
      totalDays: totalDays || 1,
      lastLoginDate: this._todayStr(),
      loginTime: Date.now()
    };
    try {
      localStorage.setItem('samarra_user', JSON.stringify(data));
      return true;
    } catch (e) { return false; }
  },

  logout() {
    try { localStorage.removeItem('samarra_user'); } catch (e) {}
    location.href = 'login.html';
  }
};
