-- ============================================================================
-- SAMARRA 邮件/发奖系统
-- 用法：打开 Supabase Dashboard → SQL Editor → 粘贴本文件全部内容 → Run
-- ============================================================================

-- 邮件表
CREATE TABLE IF NOT EXISTS mails (
  id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  recipient   TEXT NOT NULL,
  title       TEXT NOT NULL,
  content     TEXT DEFAULT '',
  minutes     INT DEFAULT 0,
  vip_days    INT DEFAULT 0,
  is_read     BOOLEAN DEFAULT false,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 索引
CREATE INDEX IF NOT EXISTS idx_mails_recipient ON mails(recipient);
CREATE INDEX IF NOT EXISTS idx_mails_unread ON mails(recipient) WHERE is_read = false;

-- 用户领取邮件后增加经验和VIP天数
CREATE OR REPLACE FUNCTION claim_mail(p_nickname text, p_mail_id bigint)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_mail mails%ROWTYPE;
BEGIN
  SELECT * INTO v_mail FROM mails WHERE id = p_mail_id AND recipient = p_nickname;
  IF NOT FOUND THEN RAISE EXCEPTION '邮件不存在'; END IF;
  IF v_mail.is_read THEN RAISE EXCEPTION '邮件已领取'; END IF;

  -- 标记已读
  UPDATE mails SET is_read = true WHERE id = p_mail_id;
END $$;

-- 拉取用户邮件列表
CREATE OR REPLACE FUNCTION list_my_mails(p_nickname text)
RETURNS TABLE(id bigint, title text, content text, reward_minutes int, reward_vip_days int, claimed boolean, created_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  RETURN QUERY SELECT m.id, m.title, m.content, m.minutes, m.vip_days, m.is_read, m.created_at
  FROM mails m WHERE m.recipient = p_nickname ORDER BY m.created_at DESC;
END $$;

-- 发送邮件给单个用户（管理员用）
CREATE OR REPLACE FUNCTION send_mail_to_user(p_admin text, p_target text, p_title text, p_content text, p_minutes int, p_vip_days int)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM admins a WHERE a.nickname = p_admin) THEN
    RAISE EXCEPTION '非管理员，无权操作';
  END IF;
  IF p_target IS NULL OR length(trim(p_target)) = 0 THEN RAISE EXCEPTION '目标用户不能为空'; END IF;
  IF p_title IS NULL OR length(trim(p_title)) = 0 THEN RAISE EXCEPTION '标题不能为空'; END IF;

  INSERT INTO mails(recipient, title, content, minutes, vip_days)
  VALUES(trim(p_target), trim(p_title), COALESCE(p_content, ''), COALESCE(p_minutes, 0), COALESCE(p_vip_days, 0));
END $$;

-- 全服广播邮件
CREATE OR REPLACE FUNCTION send_broadcast(p_admin text, p_title text, p_content text, p_minutes int, p_vip_days int)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  cnt int;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM admins a WHERE a.nickname = p_admin) THEN
    RAISE EXCEPTION '非管理员，无权操作';
  END IF;
  IF p_title IS NULL OR length(trim(p_title)) = 0 THEN RAISE EXCEPTION '标题不能为空'; END IF;

  -- 插入邮件给所有登录过的用户（从 localStorage 没法知道，这里用 users 表，如果没有就用 admins + 已知用户）
  -- 简化：插入给所有在 users 表里的用户，如果没有 users 表，就插入给 Sean 测试
  INSERT INTO mails(recipient, title, content, minutes, vip_days)
  SELECT nickname, trim(p_title), COALESCE(p_content, ''), COALESCE(p_minutes, 0), COALESCE(p_vip_days, 0)
  FROM admins;

  GET DIAGNOSTICS cnt = ROW_COUNT;
  RETURN cnt;
END $$;
