# SAMARRA · 网页游戏平台

基于 **Supabase（PostgreSQL RPC）+ 纯 HTML/CSS/JS** 的全栈网页游戏平台，包含：

- 🃏 **斗地主**：2 人单挑 / 3 人经典 / 4 人两副牌。洗牌、发牌、叫地主、牌型校验、轮转、胜负判定全部在 Supabase RPC 中完成，前端只做 UI 与动画（零外部 JS 依赖，仅 shared/common.css 共享样式）。
- 📖 **文字冒险**：可视化思维导图编辑器（拖拽连线、节点编辑）+ 玩家端，存档**强绑定设备昵称**（localStorage 昵称 → story_progress 表）。
- 👑 **管理员系统**：admins 表记录管理员昵称，仅管理员大厅可见"管理后台"入口；非管理员访问 admin 页面会被拦截。

## 目录结构

```
├── login.html                # 登录：昵称绑定设备（localStorage）
├── index.html                # 大厅：昵称/退出/管理员入口/创建加入房间/座位展示
├── admin.html                # 管理后台入口（非管理员拦截）
├── games/
│   ├── doudizhu.html         # 斗地主对局：叫地主/发牌动画/出牌/倒计时自动过
│   └── story.html            # 文字冒险玩家端（存档续玩）
├── admin/
│   └── story-editor.html     # 文字游戏编辑器：思维导图拖拽连线 + 节点编辑
├── shared/
│   └── common.css            # 全局样式（#f3f4f6 浅灰、胶囊按钮、白卡片、皇冠等级）
└── sql/
    └── schema.sql            # 全量数据库脚本：建表 + 全部 RPC 函数 + 种子数据
```

## 部署步骤

### 1. 初始化数据库（Supabase）

1. 打开 [Supabase Dashboard](https://supabase.com/dashboard) → 选择项目 `djvsugbstenltenktpwv` → **SQL Editor**。
2. 把 `sql/schema.sql` 的**全部内容**粘贴进去 → **Run**。
3. 脚本会 DROP 旧表并重建：`admins`、`game_rooms`、`stories`、`story_nodes`、`story_progress`，并创建全部 RPC 函数与示例故事《勇者斗恶龙》。

> 表与函数均开启 RLS，前端一律通过 RPC 访问，anon key 无法直连数据表。

### 2. 配置前端 Supabase 地址 / Anon Key

所有页面的 `<script>` 顶部都有：

```js
const SB = {
  url: "https://djvsugbstenltenktpwv.supabase.co",
  key: "eyJhbGciOiJIUzI1NiIs..." // ← 换成你当前有效的 anon key
};
```

如果报 `Invalid API key`，请到 Supabase Dashboard → **Settings → API Keys** 复制当前 `anon` key 替换。也可以用全局替换一次性更新所有页面。

### 3. 部署静态页面（GitHub Pages / 任意静态托管）

将本目录作为站点根目录上传（保持 `login.html` 在根），例如 GitHub Pages：

```
https://<你的用户名>.github.io/<仓库名>/
```

## 管理员说明

- 默认管理员昵称：**`admin`**（`schema.sql` 种子数据已插入，`ON CONFLICT DO NOTHING`，重复执行不会重复插入）。
- 以昵称 `admin` 登录后，大厅右上角会出现 **管理后台** 入口。
- 自由增删管理员（在 SQL Editor 执行）：

```sql
-- 新增
INSERT INTO admins (nickname) VALUES ('你的昵称') ON CONFLICT DO NOTHING;
-- 删除
DELETE FROM admins WHERE nickname = '你的昵称';
```

## 测试管理员方式

1. 打开 `login.html`，昵称输入 `admin` → 进入大厅 → 右上角出现"管理后台"。
2. 点击进入 → 点"文字游戏编辑器"→ 选择《勇者斗恶龙》或新建故事 → 左侧拖拽节点/连线，右侧编辑内容 → 保存。
3. 玩家端：大厅 → 文字冒险 → 选择故事即可开始，进度自动按昵称存档。

## 技术说明

- **前后端绝对分离**：所有核心判定（牌型 `_classify`、压牌 `_beats`、洗牌发牌 `_shuffle_deal`、叫地主 `bid`、出牌 `play_cards`、过牌 `pass_turn`、超时 `auto_pass`）都是 Supabase RPC，前端 `fetch` 调用。
- **性能**：全站点击粒子动效为 Canvas 实现，单次 12 粒、队列上限 60，不会卡顿。
- 斗地主发牌动画约 7.5 秒，从屏幕上方/中心逐张飞向手牌。
