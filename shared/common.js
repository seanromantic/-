/* ===== CSS 变量 ===== */
:root {
  --color-primary: #5b8cff;
  --color-primary-light: #8e6bff;
  --color-bg: #eef2f7;
  --color-card: #fff;
  --color-text: #1e293b;
  --color-text-light: #64748b;
  --color-border: #e2e8f0;
  --radius-pill: 999px;
  --radius-card: 14px;
  --shadow-card: 0 2px 8px rgba(0,0,0,0.04);
  --shadow-hover: 0 8px 20px rgba(91,140,255,0.15);
  --anim-duration: 0.4s;
  --anim-delay-step: 0.08s;
}

/* ===== 基础 ===== */
* { box-sizing: border-box; margin: 0; padding: 0; }
body {
  font-family: -apple-system, "PingFang SC", "Microsoft YaHei", sans-serif;
  min-height: 100vh;
  background: var(--color-bg);
  color: var(--color-text);
  padding: 20px 16px 60px;
  display: flex;
  flex-direction: column;
  align-items: center;
}

/* ===== 胶囊按钮 ===== */
.btn-pill {
  display: inline-block;
  padding: 12px 24px;
  border-radius: var(--radius-pill);
  border: none;
  font-size: 14px;
  font-weight: 600;
  cursor: pointer;
  transition: all 0.2s ease;
  box-shadow: 0 2px 6px rgba(0,0,0,0.05);
  text-align: center;
  text-decoration: none;
}
.btn-pill:active { transform: scale(0.97); }
.btn-primary {
  background: linear-gradient(90deg, var(--color-primary), var(--color-primary-light));
  color: #fff;
  box-shadow: 0 4px 12px rgba(91,140,255,0.3);
}
.btn-primary:hover { opacity: 0.92; transform: translateY(-2px); }
.btn-secondary {
  background: var(--color-card);
  color: var(--color-primary);
  border: 1px solid var(--color-border);
}
.btn-secondary:hover { background: #f1f5f9; transform: translateY(-2px); }

/* ===== 卡片 ===== */
.card {
  background: var(--color-card);
  border: 1px solid var(--color-border);
  border-radius: var(--radius-card);
  padding: 14px;
  box-shadow: var(--shadow-card);
  transition: all 0.2s ease;
}
.card:hover {
  transform: translateY(-2px);
  box-shadow: var(--shadow-hover);
}

/* ===== 胶囊输入框 ===== */
.input-pill {
  width: 100%;
  padding: 12px 20px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-pill);
  font-size: 14px;
  outline: none;
  background: var(--color-card);
  text-align: center;
  box-shadow: 0 1px 3px rgba(0,0,0,0.03);
}
.input-pill:focus { border-color: var(--color-primary); }

/* ===== 头像 ===== */
.avatar {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  border-radius: 50%;
  color: #fff;
  font-weight: 700;
  flex-shrink: 0;
  position: relative;
}
.avatar-sm { width: 32px; height: 32px; font-size: 14px; }
.avatar-md { width: 48px; height: 48px; font-size: 20px; }
.avatar-lg { width: 64px; height: 64px; font-size: 26px; }

/* ===== 游戏卡片（首页） ===== */
.game-card {
  display: flex;
  align-items: center;
  gap: 14px;
  background: var(--color-card);
  border: 1px solid var(--color-border);
  border-radius: var(--radius-pill);
  padding: 14px 24px;
  cursor: pointer;
  transition: all 0.2s ease;
  box-shadow: var(--shadow-card);
}
.game-card:hover {
  transform: translateY(-2px);
  box-shadow: var(--shadow-hover);
  border-color: #c7d2fe;
}
.game-card .hex { font-size: 22px; line-height: 1; }
.game-card .label {
  font-size: 15px;
  font-weight: 600;
  color: var(--color-text);
  letter-spacing: 0.5px;
}
.game-card.disabled {
  cursor: not-allowed;
  pointer-events: none;
  opacity: 0.45;
}

/* ===== 动效 ===== */
@keyframes fadeInUp {
  from { opacity: 0; transform: translateY(16px); }
  to   { opacity: 1; transform: translateY(0); }
}
@keyframes fadeInDown {
  from { opacity: 0; transform: translateY(-16px); }
  to   { opacity: 1; transform: translateY(0); }
}
@keyframes fadeInScale {
  from { opacity: 0; transform: scale(0.85); }
  to   { opacity: 1; transform: scale(1); }
}
.anim-up { animation: fadeInUp var(--anim-duration) ease both; }
.anim-down { animation: fadeInDown var(--anim-duration) ease both; }
.anim-scale { animation: fadeInScale var(--anim-duration) ease both; }
.anim-delay-1 { animation-delay: calc(var(--anim-delay-step) * 1); }
.anim-delay-2 { animation-delay: calc(var(--anim-delay-step) * 2); }
.anim-delay-3 { animation-delay: calc(var(--anim-delay-step) * 3); }
.anim-delay-4 { animation-delay: calc(var(--anim-delay-step) * 4); }
.anim-delay-5 { animation-delay: calc(var(--anim-delay-step) * 5); }

/* ===== Toast ===== */
.toast {
  position: fixed;
  bottom: 30px;
  left: 50%;
  transform: translateX(-50%) translateY(20px);
  background: rgba(30,41,59,0.9);
  color: #fff;
  padding: 10px 20px;
  border-radius: var(--radius-pill);
  font-size: 13px;
  opacity: 0;
  transition: all 0.3s ease;
  z-index: 9999;
}
.toast.show {
  opacity: 1;
  transform: translateX(-50%) translateY(0);
}/* ===== 对局玩家区 ===== */
.game-table {
  position: relative;
  width: 100%;
  max-width: 560px;
  min-height: 420px;
  margin: 0 auto 12px;
  display: flex;
  flex-direction: column;
  justify-content: space-between;
  align-items: center;
}

.player-seat {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 4px;
  position: relative;
}
.player-seat .avatar-wrap {
  position: relative;
  display: inline-block;
}
.player-seat .status-dot {
  position: absolute;
  bottom: 2px;
  right: 2px;
  width: 10px;
  height: 10px;
  border-radius: 50%;
  border: 2px solid #fff;
}
.player-seat .status-dot.online { background: #22c55e; }
.player-seat .status-dot.offline { background: #cbd5e1; }
.player-seat .player-name {
  font-size: 12px;
  color: #334155;
  font-weight: 600;
  max-width: 80px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.player-seat .card-count {
  font-size: 11px;
  color: #64748b;
  background: #f1f5f9;
  padding: 2px 8px;
  border-radius: 999px;
}
.player-seat.active .avatar-wrap::after {
  content: '';
  position: absolute;
  inset: -4px;
  border-radius: 50%;
  border: 2px solid #ef4444;
  animation: pulseActive 1s infinite;
}
@keyframes pulseActive {
  0%, 100% { transform: scale(1); opacity: 1; }
  50% { transform: scale(1.08); opacity: 0.6; }
}
.player-seat .landlord-tag {
  position: absolute;
  top: -6px;
  left: -6px;
  background: #ef4444;
  color: #fff;
  font-size: 10px;
  padding: 1px 6px;
  border-radius: 999px;
  font-weight: 600;
}

/* 三方向布局：上、左、右 */
.seat-top { align-self: center; }
.seat-left { position: absolute; left: 0; top: 40%; transform: translateY(-50%); }
.seat-right { position: absolute; right: 0; top: 40%; transform: translateY(-50%); }
.seat-bottom { align-self: center; margin-top: auto; }

/* ===== 发牌动画 ===== */
.deal-layer {
  position: fixed;
  inset: 0;
  pointer-events: none;
  z-index: 9998;
}
.deal-card {
  position: absolute;
  width: 30px;
  height: 44px;
  background: linear-gradient(135deg, #fef3c7, #fcd34d);
  border: 1px solid #eab308;
  border-radius: 4px;
  box-shadow: 0 2px 6px rgba(0,0,0,0.15);
  transition: all 0.35s ease;
}

/* ===== 手牌横排 ===== */
.hand-row {
  display: flex;
  flex-wrap: wrap;
  gap: 4px;
  justify-content: center;
  margin: 8px 0;
  padding: 0 10px;
    }
