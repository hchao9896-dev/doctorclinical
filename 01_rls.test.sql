-- =====================================================================
-- Clinical Desk v2 · Bộ test RLS (pgTAP)
-- Chạy:  supabase start && supabase test db
-- Điều kiện: supabase-schema.sql đã nằm trong supabase/migrations/.
-- Toàn bộ chạy trong một transaction và ROLLBACK ở cuối, không để lại dữ liệu.
--
-- Cách viết: mọi kiểm tra đi qua helper cd_tests.* nhận tham số "who"
-- ('anon' | 'service' | 'postgres' | 'A' | 'B' | 'C' | 'D' | 'P'). Helper tự chuyển
-- vai trò + JWT claims, chạy câu lệnh, rồi RESET ROLE; hàm pgTAP luôn chạy bằng postgres.
--
-- Nhân vật:
--   A  = bác sĩ đã duyệt, ADMIN nhóm T1       B = bác sĩ đã duyệt, thành viên T1
--   C  = bác sĩ đã duyệt, chưa có nhóm        D = bác sĩ đã duyệt, admin nhóm T2
--   P  = tài khoản MỚI, CHƯA được duyệt
-- =====================================================================
begin;

create extension if not exists pgtap with schema extensions;
select * from no_plan();

-- ---------------------------------------------------------------------
-- Helper
-- ---------------------------------------------------------------------
create schema cd_tests;
grant usage on schema cd_tests to anon, authenticated, service_role;

create function cd_tests.u(_k text) returns uuid language sql immutable as $fn$
  select (case _k
    when 'A'  then 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    when 'B'  then 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    when 'C'  then 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
    when 'D'  then 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
    when 'P'  then 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'
    when 'T1' then '11111111-1111-4111-8111-111111111111'
    when 'T2' then '22222222-2222-4222-8222-222222222222'
  end)::uuid;
$fn$;

create function cd_tests.r(_n int) returns uuid language sql immutable as $fn$
  select ('f0000000-0000-4000-8000-' || lpad(_n::text, 12, '0'))::uuid;
$fn$;

create function cd_tests.up(_k text, _f text) returns text language sql immutable as $fn$
  select 'users/' || cd_tests.u(_k)::text || '/' || _f;
$fn$;

create function cd_tests.tp(_t text, _k text, _f text) returns text language sql immutable as $fn$
  select 'teams/' || cd_tests.u(_t)::text || '/' || cd_tests.u(_k)::text || '/' || _f;
$fn$;

-- Đặt ngữ cảnh người dùng (vai trò + JWT claims) cho phiên hiện tại.
create function cd_tests.ctx(_who text) returns void language plpgsql as $fn$
declare v uuid;
begin
  reset role;
  if _who = 'postgres' then
    return;
  elsif _who = 'anon' then
    perform set_config('request.jwt.claims', '{"role":"anon"}', true);
    perform set_config('request.jwt.claim.sub', '', true);
    perform set_config('request.jwt.claim.role', 'anon', true);
    set local role anon;
  elsif _who = 'service' then
    perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
    perform set_config('request.jwt.claim.sub', '', true);
    perform set_config('request.jwt.claim.role', 'service_role', true);
    set local role service_role;
  else
    v := cd_tests.u(_who);
    perform set_config('request.jwt.claims',
      json_build_object('sub', v::text, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v::text, true);
    perform set_config('request.jwt.claim.role', 'authenticated', true);
    set local role authenticated;
  end if;
end;
$fn$;

-- Đếm số dòng thấy được. Thiếu quyền (permission denied) coi như 0 dòng.
create function cd_tests.cnt(_who text, _sql text) returns int language plpgsql as $fn$
declare n int;
begin
  perform cd_tests.ctx(_who);
  begin
    execute 'select count(*)::int from (' || _sql || ') q' into n;
  exception when insufficient_privilege then
    n := 0;
  end;
  reset role;
  return n;
end;
$fn$;

-- Chạy DML, trả về số dòng bị tác động. Lỗi bất kỳ → -1 (kèm NOTICE) để test báo FAIL thay vì dừng cả file.
create function cd_tests.affected(_who text, _sql text) returns int language plpgsql as $fn$
declare n int;
begin
  perform cd_tests.ctx(_who);
  begin
    execute _sql;
    get diagnostics n = row_count;
  exception when others then
    n := -1;
    raise notice 'affected(%) lỗi %: %', _who, sqlstate, sqlerrm;
  end;
  reset role;
  return n;
end;
$fn$;

-- TRUE nếu câu lệnh bị lỗi với SQLSTATE nằm trong danh sách (phân tách bằng dấu phẩy).
create function cd_tests.raises(_who text, _sql text, _states text) returns boolean language plpgsql as $fn$
declare v_hit boolean := false;
begin
  perform cd_tests.ctx(_who);
  begin
    execute _sql;
    v_hit := false;
  exception when others then
    v_hit := (sqlstate = any (string_to_array(_states, ',')));
  end;
  reset role;
  return v_hit;
end;
$fn$;

-- Một số phiên bản Supabase Storage chặn DELETE trực tiếp trên storage.objects trừ khi bật cờ này.
-- Chỉ dùng trong test để kiểm tra policy; ứng dụng thật xóa file bằng Storage API.
select set_config('storage.allow_delete_query', 'true', true);

-- ---------------------------------------------------------------------
-- Dữ liệu mẫu (postgres, bỏ qua RLS)
-- ---------------------------------------------------------------------
insert into auth.users (id, aud, role, email, raw_user_meta_data, created_at, updated_at)
select cd_tests.u(k), 'authenticated', 'authenticated', lower(k) || '@test.local',
       jsonb_build_object('display_name', 'BS ' || k, 'department', 'Cấp cứu'), now(), now()
from unnest(array['A', 'B', 'C', 'D', 'P']) as k;

insert into public.approved_users (user_id)
select cd_tests.u(k) from unnest(array['A', 'B', 'C', 'D']) as k;

insert into public.teams (id, name, created_by) values
  (cd_tests.u('T1'), 'Khoa Cấp cứu', cd_tests.u('A')),
  (cd_tests.u('T2'), 'Khoa Nội',     cd_tests.u('D'));

insert into public.team_members (team_id, user_id, role) values
  (cd_tests.u('T1'), cd_tests.u('A'), 'admin'),
  (cd_tests.u('T1'), cd_tests.u('B'), 'member'),
  (cd_tests.u('T2'), cd_tests.u('D'), 'admin');

insert into public.ecg_records (id, owner_id, team_id, image_path, diagnosis) values
  (cd_tests.r(1), cd_tests.u('A'), null,              cd_tests.up('A', 'rec-a-personal.jpg'),   'A cá nhân'),
  (cd_tests.r(2), cd_tests.u('A'), cd_tests.u('T1'),  cd_tests.tp('T1', 'A', 'rec-a-team.jpg'), 'A nhóm'),
  (cd_tests.r(3), cd_tests.u('B'), null,              cd_tests.up('B', 'rec-b-personal.jpg'),   'B cá nhân'),
  (cd_tests.r(4), cd_tests.u('B'), cd_tests.u('T1'),  cd_tests.tp('T1', 'B', 'rec-b-team.jpg'), 'B nhóm'),
  (cd_tests.r(5), cd_tests.u('D'), cd_tests.u('T2'),  cd_tests.tp('T2', 'D', 'rec-d-team.jpg'), 'D nhóm T2');

insert into storage.objects (bucket_id, name)
select 'ecg-images', image_path from public.ecg_records;

-- =====================================================================
-- 0. CẤU TRÚC & CẤU HÌNH
-- =====================================================================
select is((select count(*)::int
           from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity
             and c.relname in ('profiles','teams','team_members','approved_users','ecg_records','audit_log')),
          6, '0.1 RLS bật trên cả 6 bảng');

select is((select public from storage.buckets where id = 'ecg-images'), false,
          '0.2 Bucket ecg-images là private');

select is((select data_type::text from information_schema.columns
           where table_schema = 'public' and table_name = 'ecg_records' and column_name = 'created_at'),
          'timestamp with time zone', '0.3 created_at là timestamptz');

select ok((select column_default from information_schema.columns
           where table_schema = 'public' and table_name = 'ecg_records' and column_name = 'created_at') = 'now()',
          '0.4 created_at có DEFAULT now()');

select ok(exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'ecg_records'),
          '0.5 ecg_records nằm trong publication supabase_realtime');

select set_eq(
  $$ select schemaname || '.' || tablename || '.' || policyname from pg_policies
     where (schemaname = 'public'
            and tablename in ('profiles','teams','team_members','approved_users','ecg_records'))
        or (schemaname = 'storage' and tablename = 'objects' and policyname like 'ecg_images%') $$,
  $$ values
     ('public.profiles.profiles_select_self_or_team'),
     ('public.profiles.profiles_insert_self'),
     ('public.profiles.profiles_update_self'),
     ('public.teams.teams_select_members'),
     ('public.team_members.team_members_select_team'),
     ('public.team_members.team_members_insert_admin'),
     ('public.team_members.team_members_update_admin'),
     ('public.team_members.team_members_delete_admin_or_self'),
     ('public.approved_users.approved_users_select_self'),
     ('public.ecg_records.ecg_records_select_owner_or_team'),
     ('public.ecg_records.ecg_records_insert_owner'),
     ('public.ecg_records.ecg_records_update_owner'),
     ('public.ecg_records.ecg_records_delete_owner'),
     ('storage.objects.ecg_images_select_scoped'),
     ('storage.objects.ecg_images_insert_scoped'),
     ('storage.objects.ecg_images_update_scoped'),
     ('storage.objects.ecg_images_delete_scoped') $$,
  '0.6 Đúng tập policy mong đợi, không sót policy cũ (policy permissive cộng dồn bằng OR)');

select is((select count(*)::int from pg_policies where tablename = 'audit_log'), 0,
          '0.7 audit_log không có policy nào (từ chối mặc định)');

select is((select display_name from public.profiles where id = cd_tests.u('A')), 'BS A',
          '0.8 Trigger handle_new_user tạo hồ sơ từ metadata');

select ok(not exists (select 1 from public.approved_users where user_id = cd_tests.u('P')),
          '0.9 Tài khoản mới KHÔNG tự động được duyệt');

-- =====================================================================
-- 1. ANON
-- =====================================================================
select is(cd_tests.cnt('anon', $$select 1 from public.ecg_records$$), 0, '1.1 anon không thấy ca ECG');
select ok(cd_tests.raises('anon', $$select 1 from public.ecg_records$$, '42501'),
          '1.2 anon bị từ chối quyền trên ecg_records (đã revoke)');
select ok(cd_tests.raises('anon', $$select 1 from public.profiles$$, '42501'),
          '1.3 anon bị từ chối quyền trên profiles');
select is(cd_tests.cnt('anon', $$select 1 from storage.objects where bucket_id = 'ecg-images'$$), 0,
          '1.4 anon không thấy ảnh trong bucket');
select ok(cd_tests.raises('anon', $$select public.is_team_member(cd_tests.u('T1'))$$, '42501'),
          '1.5 anon không gọi được hàm helper (đã revoke EXECUTE)');

-- =====================================================================
-- 2. TÀI KHOẢN CHƯA DUYỆT (P)
-- =====================================================================
select is(cd_tests.cnt('P', $$select 1 where public.is_approved()$$), 0, '2.1 P chưa được duyệt');
select is(cd_tests.cnt('P', $$select 1 from public.ecg_records$$), 0, '2.2 P không thấy ca nào');
select is(cd_tests.cnt('P', $$select 1 from public.profiles where id = cd_tests.u('P')$$), 1,
          '2.3 P vẫn đọc được hồ sơ của chính mình');
select is(cd_tests.cnt('P', $$select 1 from public.approved_users where user_id = cd_tests.u('P')$$), 0,
          '2.4 P thấy mình chưa có trong approved_users (app dùng để hiện "chờ duyệt")');
select ok(cd_tests.raises('P', $$insert into public.ecg_records(owner_id, image_path)
            values (cd_tests.u('P'), cd_tests.up('P', 'x.jpg'))$$, '42501'),
          '2.5 P không tạo được ca');
select ok(cd_tests.raises('P', $$insert into storage.objects(bucket_id, name)
            values ('ecg-images', cd_tests.up('P', 'x.jpg'))$$, '42501'),
          '2.6 P không tải được ảnh');

-- =====================================================================
-- 3. A: tạo/sửa ca, đường dẫn ảnh, Storage
-- =====================================================================
select is(cd_tests.cnt('A', $$select 1 where public.is_approved()$$), 1, '3.1 A đã được duyệt');

select is(cd_tests.affected('A', $$insert into public.ecg_records(owner_id, image_path)
            values (cd_tests.u('A'), cd_tests.up('A', 'new-personal.jpg'))$$), 1,
          '3.2 A tạo được ca cá nhân');
select is(cd_tests.affected('A', $$insert into public.ecg_records(owner_id, team_id, image_path)
            values (cd_tests.u('A'), cd_tests.u('T1'), cd_tests.tp('T1', 'A', 'new-team.jpg'))$$), 1,
          '3.3 A tạo được ca nhóm T1 (là thành viên)');

select ok(cd_tests.raises('A', $$insert into public.ecg_records(owner_id, image_path)
            values (cd_tests.u('B'), cd_tests.up('B', 'x.jpg'))$$, '42501'),
          '3.4 A không tạo ca mạo danh owner B');
select ok(cd_tests.raises('A', $$insert into public.ecg_records(owner_id, image_path)
            values (cd_tests.u('A'), cd_tests.up('B', 'x.jpg'))$$, '42501'),
          '3.5 A không trỏ image_path vào thư mục của B');
select ok(cd_tests.raises('A', $$insert into public.ecg_records(owner_id, team_id, image_path)
            values (cd_tests.u('A'), cd_tests.u('T2'), cd_tests.tp('T2', 'A', 'x.jpg'))$$, '42501'),
          '3.6 A không tạo ca cho nhóm T2 (không phải thành viên)');
select ok(cd_tests.raises('A', $$insert into public.ecg_records(owner_id, team_id, image_path)
            values (cd_tests.u('A'), cd_tests.u('T1'), cd_tests.tp('T1', 'B', 'x.jpg'))$$, '42501'),
          '3.7 Ca nhóm T1 của A không được trỏ vào thư mục của B');
select ok(cd_tests.raises('A', $$insert into public.ecg_records(owner_id, image_path)
            values (cd_tests.u('A'), cd_tests.up('A', 'x.exe'))$$, '42501'),
          '3.8 Từ chối đuôi tệp không hợp lệ');
select ok(cd_tests.raises('A', $$insert into public.ecg_records(owner_id, image_path)
            values (cd_tests.u('A'), cd_tests.up('A', 'sub/x.jpg'))$$, '42501'),
          '3.9 Từ chối đường dẫn lồng thêm thư mục');
select ok(cd_tests.raises('A', $$insert into public.ecg_records(owner_id, image_path, notes)
            values (cd_tests.u('A'), cd_tests.up('A', 'long.jpg'), repeat('x', 6000))$$, '23514'),
          '3.10 Từ chối ghi chú quá dài (CHECK)');

select is(cd_tests.affected('A', $$insert into public.ecg_records(owner_id, image_path, created_at)
            values (cd_tests.u('A'), cd_tests.up('A', 'future.jpg'), now() + interval '10 days')$$), 1,
          '3.11 A chèn được ca với created_at ở tương lai');
select ok((select created_at <= now() from public.ecg_records where image_path = cd_tests.up('A', 'future.jpg')),
          '3.12 Trigger kéo created_at tương lai về now()');

select is(cd_tests.cnt('A', $$select 1 from public.ecg_records where id = cd_tests.r(3)$$), 0,
          '3.13 A không thấy ca CÁ NHÂN của B');
select is(cd_tests.cnt('A', $$select 1 from public.ecg_records where id = cd_tests.r(4)$$), 1,
          '3.14 A thấy ca NHÓM của B (cùng nhóm T1)');
select is(cd_tests.cnt('A', $$select 1 from public.ecg_records where id = cd_tests.r(5)$$), 0,
          '3.15 A không thấy ca nhóm T2');

select is(cd_tests.affected('A', $$update public.ecg_records set pinned = true where id = cd_tests.r(1)$$), 1,
          '3.16 A ghim được ca của mình');
select ok(cd_tests.raises('A', $$update public.ecg_records set owner_id = cd_tests.u('B') where id = cd_tests.r(1)$$,
          '42501'), '3.17 A không chuyển chủ sở hữu ca sang B');

-- Storage
select is(cd_tests.cnt('A', $$select 1 from storage.objects where bucket_id = 'ecg-images'
            and name = cd_tests.up('A', 'rec-a-personal.jpg')$$), 1, '3.18 A đọc được ảnh cá nhân của mình');
select is(cd_tests.cnt('A', $$select 1 from storage.objects where bucket_id = 'ecg-images'
            and name = cd_tests.up('B', 'rec-b-personal.jpg')$$), 0, '3.19 A không đọc được ảnh cá nhân của B');
select is(cd_tests.cnt('A', $$select 1 from storage.objects where bucket_id = 'ecg-images'
            and name = cd_tests.tp('T1', 'B', 'rec-b-team.jpg')$$), 1, '3.20 A đọc được ảnh nhóm T1 của B');
select is(cd_tests.cnt('A', $$select 1 from storage.objects where bucket_id = 'ecg-images'
            and name = cd_tests.tp('T2', 'D', 'rec-d-team.jpg')$$), 0, '3.21 A không đọc được ảnh nhóm T2');

select is(cd_tests.affected('A', $$insert into storage.objects(bucket_id, name)
            values ('ecg-images', cd_tests.up('A', 'up1.jpg'))$$), 1, '3.22 A tải ảnh vào thư mục của mình');
select ok(cd_tests.raises('A', $$insert into storage.objects(bucket_id, name)
            values ('ecg-images', cd_tests.up('B', 'up.jpg'))$$, '42501'), '3.23 A không tải ảnh vào thư mục của B');
select ok(cd_tests.raises('A', $$insert into storage.objects(bucket_id, name)
            values ('ecg-images', cd_tests.tp('T2', 'A', 'up.jpg'))$$, '42501'), '3.24 A không tải ảnh vào nhóm T2');
select ok(cd_tests.raises('A', $$insert into storage.objects(bucket_id, name)
            values ('ecg-images', cd_tests.tp('T1', 'B', 'up.jpg'))$$, '42501'),
          '3.25 A không tải ảnh vào thư mục của B trong nhóm T1');
select ok(cd_tests.raises('A', $$insert into storage.objects(bucket_id, name)
            values ('ecg-images', cd_tests.up('A', 'sub/up.jpg'))$$, '42501'), '3.26 Storage từ chối đường dẫn lồng');
select ok(cd_tests.raises('A', $$insert into storage.objects(bucket_id, name)
            values ('ecg-images', cd_tests.up('A', 'up.exe'))$$, '42501'), '3.27 Storage từ chối đuôi .exe');

select is(cd_tests.affected('A', $$update storage.objects set metadata = '{"cd":1}'::jsonb
            where bucket_id = 'ecg-images' and name = cd_tests.up('A', 'rec-a-personal.jpg')$$), 1,
          '3.28 A cập nhật được object của mình (cần cho upsert)');
select is(cd_tests.affected('A', $$delete from storage.objects
            where bucket_id = 'ecg-images' and name = cd_tests.up('A', 'up1.jpg')$$), 1,
          '3.29 A xóa được object của mình');

-- =====================================================================
-- 4. B (thành viên thường)
-- =====================================================================
select is(cd_tests.cnt('B', $$select 1 from public.ecg_records where id = cd_tests.r(2)$$), 1,
          '4.1 B thấy ca nhóm của A');
select is(cd_tests.cnt('B', $$select 1 from public.ecg_records where id = cd_tests.r(1)$$), 0,
          '4.2 B không thấy ca cá nhân của A');
select is(cd_tests.cnt('B', $$select 1 from public.ecg_records where id = cd_tests.r(3)$$), 1,
          '4.3 B thấy ca cá nhân của chính mình');
select is(cd_tests.affected('B', $$update public.ecg_records set pinned = true where id = cd_tests.r(2)$$), 0,
          '4.4 B không sửa được ca nhóm của A');
select is(cd_tests.affected('B', $$delete from public.ecg_records where id = cd_tests.r(2)$$), 0,
          '4.5 B không xóa được ca nhóm của A');
select is(cd_tests.cnt('B', $$select 1 from storage.objects where bucket_id = 'ecg-images'
            and name = cd_tests.tp('T1', 'A', 'rec-a-team.jpg')$$), 1, '4.6 B đọc được ảnh nhóm của A');
select is(cd_tests.cnt('B', $$select 1 from storage.objects where bucket_id = 'ecg-images'
            and name = cd_tests.up('A', 'rec-a-personal.jpg')$$), 0, '4.7 B không đọc được ảnh cá nhân của A');
select ok(cd_tests.raises('B', $$insert into storage.objects(bucket_id, name)
            values ('ecg-images', cd_tests.tp('T1', 'A', 'hack.jpg'))$$, '42501'),
          '4.8 B không tải ảnh mạo danh thư mục của A');
select is(cd_tests.affected('B', $$insert into storage.objects(bucket_id, name)
            values ('ecg-images', cd_tests.tp('T1', 'B', 'up2.jpg'))$$), 1, '4.9 B tải được ảnh nhóm của mình');
select is(cd_tests.affected('B', $$update storage.objects set metadata = '{"hack":1}'::jsonb
            where bucket_id = 'ecg-images' and name = cd_tests.up('A', 'rec-a-personal.jpg')$$), 0,
          '4.10 B không cập nhật được object của A');
select is(cd_tests.affected('B', $$delete from storage.objects
            where bucket_id = 'ecg-images' and name = cd_tests.up('A', 'rec-a-personal.jpg')$$), 0,
          '4.11 B không xóa được object của A');
select ok(cd_tests.raises('B', $$insert into public.team_members(team_id, user_id, role)
            values (cd_tests.u('T1'), cd_tests.u('C'), 'member')$$, '42501'),
          '4.12 Thành viên thường không thêm được người vào nhóm');
select is(cd_tests.cnt('B', $$select 1 from public.team_members where team_id = cd_tests.u('T1')$$), 2,
          '4.13 B thấy danh sách thành viên nhóm T1 (A, B)');
select is(cd_tests.affected('B', $$update public.team_members set role = 'admin'
            where team_id = cd_tests.u('T1') and user_id = cd_tests.u('B')$$), 0,
          '4.14 B không tự nâng quyền admin');

-- =====================================================================
-- 5. ADMIN NHÓM & ĐỒNG BỘ profiles.team_id
-- =====================================================================
select is(cd_tests.affected('A', $$insert into public.team_members(team_id, user_id, role)
            values (cd_tests.u('T1'), cd_tests.u('C'), 'member')$$), 1, '5.1 Admin A thêm được C vào T1');
select ok(cd_tests.raises('A', $$insert into public.team_members(team_id, user_id, role)
            values (cd_tests.u('T1'), cd_tests.u('P'), 'member')$$, '42501'),
          '5.2 Admin không thêm được tài khoản CHƯA duyệt');
select ok(cd_tests.raises('A', $$insert into public.team_members(team_id, user_id, role)
            values (cd_tests.u('T2'), cd_tests.u('C'), 'member')$$, '42501'),
          '5.3 A không phải admin T2 nên không thêm người vào T2');

select is((select team_id from public.profiles where id = cd_tests.u('C')), cd_tests.u('T1'),
          '5.4 Trigger đồng bộ profiles.team_id khi thêm thành viên');
select is(cd_tests.cnt('C', $$select 1 from public.ecg_records where id = cd_tests.r(2)$$), 1,
          '5.5 C thành viên mới → thấy ca nhóm');
select is(cd_tests.cnt('C', $$select 1 from public.ecg_records where id = cd_tests.r(1)$$), 0,
          '5.6 C vẫn không thấy ca cá nhân của A');

select is(cd_tests.affected('A', $$delete from public.team_members
            where team_id = cd_tests.u('T1') and user_id = cd_tests.u('C')$$), 1, '5.7 Admin A gỡ được C khỏi nhóm');
select ok((select team_id is null from public.profiles where id = cd_tests.u('C')),
          '5.8 Trigger xóa profiles.team_id khi gỡ thành viên');
select is(cd_tests.cnt('C', $$select 1 from public.ecg_records where id = cd_tests.r(2)$$), 0,
          '5.9 C bị gỡ khỏi nhóm → mất quyền xem ca nhóm ngay lập tức');

select is(cd_tests.cnt('D', $$select 1 from public.team_members where team_id = cd_tests.u('T1')$$), 0,
          '5.10 D (nhóm khác) không thấy thành viên T1');
select is(cd_tests.cnt('D', $$select 1 from public.ecg_records where id = cd_tests.r(2)$$), 0,
          '5.11 D không thấy ca nhóm T1');

-- =====================================================================
-- 6. profiles
-- =====================================================================
select is(cd_tests.affected('A', $$update public.profiles set display_name = 'BS A (sửa)'
            where id = cd_tests.u('A')$$), 1, '6.1 A sửa được hồ sơ của mình');
select ok(cd_tests.raises('A', $$update public.profiles set team_id = cd_tests.u('T2')
            where id = cd_tests.u('A')$$, '42501'), '6.2 A không tự gán mình vào nhóm T2');
select is(cd_tests.affected('A', $$update public.profiles set display_name = 'hack'
            where id = cd_tests.u('B')$$), 0, '6.3 A không sửa được hồ sơ của B');
select is(cd_tests.cnt('B', $$select 1 from public.profiles where id = cd_tests.u('A')$$), 1,
          '6.4 B (cùng nhóm) đọc được hồ sơ của A');
select is(cd_tests.cnt('D', $$select 1 from public.profiles where id = cd_tests.u('A')$$), 0,
          '6.5 D (khác nhóm) không đọc được hồ sơ của A');
select is(cd_tests.cnt('C', $$select 1 from public.profiles where id = cd_tests.u('D')$$), 0,
          '6.6 C (không nhóm) không đọc được hồ sơ của D');

-- =====================================================================
-- 7. LEO THANG ĐẶC QUYỀN (người dùng đã duyệt nhưng không phải admin hệ thống)
-- =====================================================================
select ok(cd_tests.raises('C', $$insert into public.approved_users(user_id) values (cd_tests.u('P'))$$, '42501'),
          '7.1 Người dùng không tự duyệt tài khoản bằng INSERT');
select ok(cd_tests.raises('C', $$select public.approve_user(cd_tests.u('P'))$$, '42501'),
          '7.2 Người dùng không gọi được approve_user()');
select ok(cd_tests.raises('C', $$select * from public.ecg_expired_records(30, 10)$$, '42501'),
          '7.3 Người dùng không gọi được ecg_expired_records()');
select ok(cd_tests.raises('C', $$select * from public.ecg_orphan_objects(interval '1 day', 10)$$, '42501'),
          '7.4 Người dùng không gọi được ecg_orphan_objects()');
select ok(cd_tests.raises('C', $$select 1 from public.audit_log$$, '42501'),
          '7.5 Người dùng không đọc được audit_log');
select ok(cd_tests.raises('C', $$select public.admin_create_team('x', cd_tests.u('C'))$$, '42501'),
          '7.6 Người dùng không gọi được admin_create_team()');
select ok(cd_tests.raises('C', $$insert into public.teams(name, created_by) values ('x', cd_tests.u('C'))$$, '42501'),
          '7.7 Người dùng không tự tạo nhóm bằng INSERT');
select ok(cd_tests.raises('C', $$truncate public.ecg_records$$, '42501'),
          '7.8 Người dùng không có quyền TRUNCATE');
select ok(cd_tests.raises('P', $$select public.approve_user(cd_tests.u('P'))$$, '42501'),
          '7.9 Tài khoản chưa duyệt không tự duyệt chính mình');

-- =====================================================================
-- 8. HẾT HẠN, MỒ CÔI, TRIGGER THỜI GIAN (service_role)
-- =====================================================================
insert into public.ecg_records (id, owner_id, image_path, pinned, created_at) values
  (cd_tests.r(10), cd_tests.u('A'), cd_tests.up('A', 'old-unpinned.jpg'),            false, now() - interval '40 days'),
  (cd_tests.r(11), cd_tests.u('A'), cd_tests.up('A', 'old-pinned.jpg'),              true,  now() - interval '40 days'),
  (cd_tests.r(12), cd_tests.u('A'), cd_tests.up('A', 'new-unpinned.jpg'),            false, now()),
  (cd_tests.r(13), cd_tests.u('A'), cd_tests.up('A', 'old-recently-unpinned.jpg'),   true,  now() - interval '40 days');
update public.ecg_records set pinned = false where id = cd_tests.r(13);

select ok((select unpinned_at is not null from public.ecg_records where id = cd_tests.r(13)),
          '8.1 Bỏ ghim → server đặt unpinned_at');
select ok((select unpinned_at is null from public.ecg_records where id = cd_tests.r(10)),
          '8.2 Ca chưa từng ghim: unpinned_at rỗng');

select is(cd_tests.affected('A', $$update public.ecg_records set unpinned_at = now() + interval '1 year'
            where id = cd_tests.r(10)$$), 1, '8.3 A cố gán unpinned_at tương lai');
select ok((select unpinned_at is null from public.ecg_records where id = cd_tests.r(10)),
          '8.4 Client không giả được unpinned_at để né xóa');

select is(cd_tests.cnt('service', $$select 1 from public.ecg_expired_records(30, 100)$$), 1,
          '8.5 Chỉ đúng 1 ca hết hạn (không ghim, quá 40 ngày)');
select is(cd_tests.cnt('service', $$select 1 from public.ecg_expired_records(30, 100)
            where id = cd_tests.r(10)$$), 1, '8.6 Đó là ca old-unpinned');
select is(cd_tests.cnt('service', $$select 1 from public.ecg_expired_records(30, 100)
            where id in (cd_tests.r(11), cd_tests.r(12), cd_tests.r(13))$$), 0,
          '8.7 Ca đang ghim / mới tạo / vừa bỏ ghim đều KHÔNG bị liệt kê');

insert into storage.objects (bucket_id, name, created_at) values
  ('ecg-images', cd_tests.up('A', 'orphan-old.jpg'), now() - interval '3 days'),
  ('ecg-images', cd_tests.up('A', 'orphan-new.jpg'), now());

select is(cd_tests.cnt('service', $$select 1 from public.ecg_orphan_objects(interval '1 day', 100)
            where name = cd_tests.up('A', 'orphan-old.jpg')$$), 1, '8.8 File mồ côi cũ được liệt kê');
select is(cd_tests.cnt('service', $$select 1 from public.ecg_orphan_objects(interval '1 day', 100)
            where name = cd_tests.up('A', 'orphan-new.jpg')$$), 0, '8.9 File mồ côi mới (<1 ngày) chưa bị đụng tới');
select is(cd_tests.cnt('service', $$select 1 from public.ecg_orphan_objects(interval '1 day', 100)
            where name = cd_tests.tp('T1', 'A', 'rec-a-team.jpg')$$), 0, '8.10 File còn bản ghi tham chiếu không bị liệt kê');

-- =====================================================================
-- 9. CHỦ ẢNH RỜI NHÓM
-- =====================================================================
delete from public.team_members where team_id = cd_tests.u('T1') and user_id = cd_tests.u('B');

select ok((select team_id is null from public.profiles where id = cd_tests.u('B')),
          '9.1 B rời nhóm → profiles.team_id về rỗng');
select is(cd_tests.cnt('B', $$select 1 from public.ecg_records where id = cd_tests.r(4)$$), 1,
          '9.2 B vẫn thấy ca nhóm do chính mình tạo');
select is(cd_tests.cnt('B', $$select 1 from storage.objects where bucket_id = 'ecg-images'
            and name = cd_tests.tp('T1', 'B', 'rec-b-team.jpg')$$), 1,
          '9.3 B vẫn đọc được ẢNH nhóm của chính mình sau khi rời nhóm');
select is(cd_tests.cnt('B', $$select 1 from public.ecg_records where id = cd_tests.r(2)$$), 0,
          '9.4 B không còn thấy ca nhóm của A');
select is(cd_tests.cnt('B', $$select 1 from storage.objects where bucket_id = 'ecg-images'
            and name = cd_tests.tp('T1', 'A', 'rec-a-team.jpg')$$), 0,
          '9.5 B không còn đọc được ảnh nhóm của A');
select ok(cd_tests.raises('B', $$update public.ecg_records set pinned = true where id = cd_tests.r(4)$$, '42501'),
          '9.6 B không sửa được ca nhóm sau khi rời (chỉ còn xóa)');
select ok(cd_tests.raises('B', $$insert into storage.objects(bucket_id, name)
            values ('ecg-images', cd_tests.tp('T1', 'B', 'again.jpg'))$$, '42501'),
          '9.7 B không tải thêm ảnh vào nhóm đã rời');
select is(cd_tests.affected('B', $$delete from storage.objects where bucket_id = 'ecg-images'
            and name = cd_tests.tp('T1', 'B', 'up2.jpg')$$), 1, '9.8 B vẫn xóa được ảnh của mình trong nhóm cũ');
select is(cd_tests.affected('B', $$delete from public.ecg_records where id = cd_tests.r(4)$$), 1,
          '9.9 B xóa được ca nhóm của mình');

-- File của ca vừa xóa trở thành mồ côi → job dọn dẹp phải thấy sau khi đủ cũ.
update storage.objects set created_at = now() - interval '3 days'
where bucket_id = 'ecg-images' and name = cd_tests.tp('T1', 'B', 'rec-b-team.jpg');
select is(cd_tests.cnt('service', $$select 1 from public.ecg_orphan_objects(interval '1 day', 100)
            where name = cd_tests.tp('T1', 'B', 'rec-b-team.jpg')$$), 1,
          '9.10 Xóa dòng mà sót file → file được liệt kê là mồ côi');

-- =====================================================================
-- 10. AUDIT
-- =====================================================================
select ok(exists (select 1 from public.audit_log where action = 'INSERT' and record_id = cd_tests.r(1)),
          '10.1 Audit ghi lần tạo ca');
select ok(exists (select 1 from public.audit_log
                  where action = 'UPDATE' and record_id = cd_tests.r(1) and actor_id = cd_tests.u('A')),
          '10.2 Audit ghi người ghim ca (A)');
select ok(exists (select 1 from public.audit_log
                  where action = 'DELETE' and record_id = cd_tests.r(4) and actor_id = cd_tests.u('B')),
          '10.3 Audit ghi người xóa ca (B)');
select ok(not exists (select 1 from public.audit_log where detail::text ilike '%BN Ẩn danh%'
                                                       or detail::text ilike '%A cá nhân%'),
          '10.4 Audit không chứa tên bệnh nhân / chẩn đoán');

-- =====================================================================
-- 11. HẠN MỨC
-- =====================================================================
insert into public.ecg_records (owner_id, image_path)
select cd_tests.u('C'), cd_tests.up('C', 'q' || g || '.jpg')
from generate_series(1, public.ecg_max_records_per_user()) as g;

select ok(cd_tests.raises('C', $$insert into public.ecg_records(owner_id, image_path)
            values (cd_tests.u('C'), cd_tests.up('C', 'over.jpg'))$$, '54000'),
          '11.1 Vượt hạn mức ca/người → lỗi 54000');
select is(cd_tests.affected('D', $$insert into public.ecg_records(owner_id, image_path)
            values (cd_tests.u('D'), cd_tests.up('D', 'ok.jpg'))$$), 1,
          '11.2 Hạn mức tính riêng từng người (D vẫn tạo được)');

-- =====================================================================
-- 12. RÀNG BUỘC KHÓA NGOẠI
-- =====================================================================
select ok(cd_tests.raises('postgres', $$delete from public.teams where id = cd_tests.u('T1')$$, '23503,23001'),
          '12.1 Không xóa được nhóm còn ca ECG (ON DELETE RESTRICT)');

select * from finish();
rollback;
