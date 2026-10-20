create or replace function admin_list_admins(p_admin text)
returns table(nickname text) language plpgsql security definer set search_path = public as $$
begin
  if not exists(select 1 from admins a where a.nickname = p_admin) then
    raise exception '非管理员，无权操作';
  end if;
  return query select a.nickname::text from admins a order by a.id asc;
end $$;

create or replace function admin_add_admin(p_admin text, p_target text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists(select 1 from admins a where a.nickname = p_admin) then
    raise exception '非管理员，无权操作';
  end if;
  if p_target is null or length(trim(p_target)) = 0 then raise exception '昵称不能为空'; end if;
  insert into admins(nickname) select trim(p_target)
  where not exists (select 1 from admins a where a.nickname = trim(p_target));
end $$;

create or replace function admin_remove_admin(p_admin text, p_target text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists(select 1 from admins a where a.nickname = p_admin) then
    raise exception '非管理员，无权操作';
  end if;
  if p_target = p_admin then raise exception '不能移除当前登录的管理员自己'; end if;
  delete from admins a where a.nickname = p_target;
end $$;

create or replace function admin_list_rooms(p_admin text)
returns table(room_code text, max_players int, status text, player_count int)
language plpgsql security definer set search_path = public as $$
begin
  if not exists(select 1 from admins a where a.nickname = p_admin) then
    raise exception '非管理员，无权操作';
  end if;
  return query select r.room_code::text, r.max_players, r.status::text,
    coalesce(jsonb_array_length(r.players), 0) from game_rooms r order by r.id desc;
end $$;

create or replace function admin_dismiss_room(p_admin text, p_room_code text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists(select 1 from admins a where a.nickname = p_admin) then
    raise exception '非管理员，无权操作';
  end if;
  delete from game_rooms r where r.room_code = p_room_code;
end $$;
