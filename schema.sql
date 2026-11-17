-- ============================================================================
--  واصل الإمارات — Wasel UAE
--  مخطط قاعدة البيانات الإنتاجي (Supabase / PostgreSQL)
--  التاريخ: 2026-11
--  التشغيل: Supabase Dashboard → SQL Editor → الصق هذا الملف كاملاً → Run
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) الإضافات الأساسية
-- ----------------------------------------------------------------------------
create extension if not exists "pgcrypto";        -- gen_random_uuid()
create extension if not exists "pg_trgm";          -- بحث نصي سريع

-- ----------------------------------------------------------------------------
-- 2) جدول الملفات الشخصية (يمتد auth.users)
--    كل مستخدم في Supabase Auth يُنشأ له صف هنا تلقائياً عبر الـ trigger أدناه
-- ----------------------------------------------------------------------------
create table if not exists public.profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  phone         text unique,
  full_name     text default '',
  role          text not null default 'CUSTOMER'
                check (role in ('CUSTOMER','DRIVER','ADMIN')),
  email         text,
  avatar_url    text,
  -- حقول السائقين (تُملأ فقط إذا role = 'DRIVER')
  vehicle_type  text,
  plate_number  text,
  asateel_permit text,
  rating        numeric(2,1) default 5.0,
  trips_count   integer default 0,
  is_active     boolean default true,
  created_at    timestamptz default now(),
  updated_at    timestamptz default now()
);

create index if not exists idx_profiles_phone on public.profiles(phone);
create index if not exists idx_profiles_role on public.profiles(role);

-- ----------------------------------------------------------------------------
-- 3) الطلبيات
-- ----------------------------------------------------------------------------
create table if not exists public.orders (
  id              uuid primary key default gen_random_uuid(),
  code            text unique,                          -- WAS-101, WAS-102...
  customer_id     uuid references public.profiles(id) on delete set null,
  driver_id       uuid references public.profiles(id) on delete set null,
  category        text not null,                        -- GIFTS_PERFUMES, PETS_BIRDS, ...
  vehicle_type    text,
  description     text,
  pickup_emirate  text not null,
  pickup_area     text,
  pickup_lat      double precision,
  pickup_lng      double precision,
  delivery_emirate text not null,
  delivery_area   text,
  delivery_lat    double precision,
  delivery_lng    double precision,
  distance_km     numeric(6,1),
  base_price      numeric(10,2) not null,
  min_price       numeric(10,2),
  salik_charge    numeric(10,2) default 0,
  darb_charge     numeric(10,2) default 0,
  final_price     numeric(10,2),
  pin_code        text,                                 -- رمز التحقق 4 أرقام
  status          text not null default 'WAITING_FOR_BIDS'
                  check (status in ('WAITING_FOR_BIDS','BID_ACCEPTED',
                                    'DRIVER_EN_ROUTE_PICKUP','PICKED_UP',
                                    'IN_TRANSIT','DELIVERED','CANCELLED')),
  created_at      timestamptz default now(),
  updated_at      timestamptz default now(),
  accepted_at     timestamptz,
  delivered_at    timestamptz
);

create index if not exists idx_orders_customer on public.orders(customer_id);
create index if not exists idx_orders_driver   on public.orders(driver_id);
create index if not exists idx_orders_status   on public.orders(status);
create index if not exists idx_orders_created  on public.orders(created_at desc);

-- ----------------------------------------------------------------------------
-- 4) العروض (المزايدة العكسية)
-- ----------------------------------------------------------------------------
create table if not exists public.bids (
  id          uuid primary key default gen_random_uuid(),
  order_id    uuid not null references public.orders(id) on delete cascade,
  driver_id   uuid not null references public.profiles(id) on delete cascade,
  amount      numeric(10,2) not null,
  message     text,
  eta_minutes integer,
  status      text not null default 'PENDING'
              check (status in ('PENDING','ACCEPTED','REJECTED')),
  created_at  timestamptz default now()
);

create index if not exists idx_bids_order  on public.bids(order_id);
create index if not exists idx_bids_driver on public.bids(driver_id);
create index if not exists idx_bids_status on public.bids(status);

-- ----------------------------------------------------------------------------
-- 5) رسائل المحادثة بين التاجر والكابتن
-- ----------------------------------------------------------------------------
create table if not exists public.messages (
  id          uuid primary key default gen_random_uuid(),
  order_id    uuid not null references public.orders(id) on delete cascade,
  sender_id   uuid not null references public.profiles(id) on delete cascade,
  text        text not null,
  created_at  timestamptz default now()
);

create index if not exists idx_messages_order on public.messages(order_id, created_at);

-- ----------------------------------------------------------------------------
-- 6) الإشعارات
-- ----------------------------------------------------------------------------
create table if not exists public.notifications (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles(id) on delete cascade,
  type        text not null,           -- bid:new, bid:accepted, status:changed, chat:message
  title       text not null,
  body        text,
  data        jsonb,
  is_read     boolean default false,
  created_at  timestamptz default now()
);

create index if not exists idx_notif_user on public.notifications(user_id, is_read, created_at desc);

-- ----------------------------------------------------------------------------
-- 7) تتبع حركة الكابتن (Live Tracking)
-- ----------------------------------------------------------------------------
create table if not exists public.driver_locations (
  id          uuid primary key default gen_random_uuid(),
  driver_id   uuid not null references public.profiles(id) on delete cascade,
  order_id    uuid references public.orders(id) on delete set null,
  lat         double precision not null,
  lng         double precision not null,
  heading     numeric(5,2),
  speed       numeric(5,2),
  recorded_at timestamptz default now()
);

create index if not exists idx_dl_driver on public.driver_locations(driver_id, recorded_at desc);

-- ----------------------------------------------------------------------------
-- 8) دالة تحديث updated_at تلقائياً
-- ----------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_profiles_updated on public.profiles;
create trigger trg_profiles_updated before update on public.profiles
  for each row execute function public.set_updated_at();

drop trigger if exists trg_orders_updated on public.orders;
create trigger trg_orders_updated before update on public.orders
  for each row execute function public.set_updated_at();

-- ----------------------------------------------------------------------------
-- 9) إنشاء ملف شخصي تلقائياً عند تسجيل مستخدم جديد في auth.users
-- ----------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, phone, email, full_name)
  values (
    new.id,
    new.phone,
    new.email,
    coalesce(new.raw_user_meta_data->>'full_name',
             new.raw_user_meta_data->>'name', '')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ----------------------------------------------------------------------------
-- 10) دالة توليد رمز الطلب (WAS-101)
-- ----------------------------------------------------------------------------
create or replace function public.next_order_code()
returns text
language plpgsql
security definer set search_path = public
as $$
declare
  seq_val integer;
begin
  select coalesce(max(code_seq), 100) + 1 into seq_val
  from (select (regexp_match(code, 'WAS-(\d+)'))[1]::int as code_seq from public.orders) s;
  return 'WAS-' || seq_val::text;
end;
$$;

-- ----------------------------------------------------------------------------
-- 11) Row Level Security (RLS) — حماية البيانات حسب المستخدم
-- ----------------------------------------------------------------------------
alter table public.profiles          enable row level security;
alter table public.orders            enable row level security;
alter table public.bids              enable row level security;
alter table public.messages          enable row level security;
alter table public.notifications     enable row level security;
alter table public.driver_locations enable row level security;

-- ===== profiles: المستخدم يرى ملفه، والكل يرى السائقين النشطين =====
drop policy if exists "profiles_select_own_or_drivers" on public.profiles;
create policy "profiles_select_own_or_drivers" on public.profiles
  for select using (
    auth.uid() = id
    or role = 'DRIVER'
    or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'ADMIN')
  );

drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own" on public.profiles
  for update using (auth.uid() = id);

drop policy if exists "profiles_admin_all" on public.profiles;
create policy "profiles_admin_all" on public.profiles
  for all using (
    exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'ADMIN')
  );

-- ===== orders: التاجر يرى طلباته، السائق يرى الطلبات المتاحة + المسندة إليه =====
drop policy if exists "orders_select_visible" on public.orders;
create policy "orders_select_visible" on public.orders
  for select using (
    customer_id = auth.uid()
    or driver_id = auth.uid()
    or status = 'WAITING_FOR_BIDS'
    or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'ADMIN')
  );

drop policy if exists "orders_insert_customer" on public.orders;
create policy "orders_insert_customer" on public.orders
  for insert with check (
    customer_id = auth.uid()
    or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'ADMIN')
  );

drop policy if exists "orders_update_owner_or_driver" on public.orders;
create policy "orders_update_owner_or_driver" on public.orders
  for update using (
    customer_id = auth.uid()
    or driver_id = auth.uid()
    or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'ADMIN')
  );

-- ===== bids: السائق يرى عروضه، التاجر يرى عروض طلبه =====
drop policy if exists "bids_select_related" on public.bids;
create policy "bids_select_related" on public.bids
  for select using (
    driver_id = auth.uid()
    or exists (select 1 from public.orders o where o.id = order_id and o.customer_id = auth.uid())
    or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'ADMIN')
  );

drop policy if exists "bids_insert_driver" on public.bids;
create policy "bids_insert_driver" on public.bids
  for insert with check (
    driver_id = auth.uid()
    and exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'DRIVER')
  );

drop policy if exists "bids_update_owner_or_customer" on public.bids;
create policy "bids_update_owner_or_customer" on public.bids
  for update using (
    driver_id = auth.uid()
    or exists (select 1 from public.orders o where o.id = order_id and o.customer_id = auth.uid())
  );

-- ===== messages: المرسل والمستلم (طرفي الطلب) =====
drop policy if exists "messages_select_related" on public.messages;
create policy "messages_select_related" on public.messages
  for select using (
    sender_id = auth.uid()
    or exists (
      select 1 from public.orders o
      where o.id = order_id
      and (o.customer_id = auth.uid() or o.driver_id = auth.uid())
    )
  );

drop policy if exists "messages_insert_participant" on public.messages;
create policy "messages_insert_participant" on public.messages
  for insert with check (
    sender_id = auth.uid()
    and exists (
      select 1 from public.orders o
      where o.id = order_id
      and (o.customer_id = auth.uid() or o.driver_id = auth.uid())
    )
  );

-- ===== notifications: كل مستخدم يرى إشعاراته فقط =====
drop policy if exists "notif_select_own" on public.notifications;
create policy "notif_select_own" on public.notifications
  for select using (user_id = auth.uid());

drop policy if exists "notif_update_own" on public.notifications;
create policy "notif_update_own" on public.notifications
  for update using (user_id = auth.uid());

drop policy if exists "notif_insert_own_or_trigger" on public.notifications;
create policy "notif_insert_own_or_trigger" on public.notifications
  for insert with check (
    user_id = auth.uid()
    or user_id in (
      select customer_id from public.orders where customer_id is not null
      union
      select driver_id from public.orders where driver_id is not null
    )
  );

-- ===== driver_locations: السائق يكتب موقعه، التاجر يقرأ موقع الكابتن المسند إليه =====
drop policy if exists "dl_insert_driver" on public.driver_locations;
create policy "dl_insert_driver" on public.driver_locations
  for insert with check (
    driver_id = auth.uid()
    and exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'DRIVER')
  );

drop policy if exists "dl_select_related" on public.driver_locations;
create policy "dl_select_related" on public.driver_locations
  for select using (
    driver_id = auth.uid()
    or exists (
      select 1 from public.orders o
      where o.driver_id = driver_locations.driver_id
      and o.customer_id = auth.uid()
    )
    or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'ADMIN')
  );

-- ----------------------------------------------------------------------------
-- 12) Realtime — تفعيل البث اللحظي على الجداول المهمة
-- ----------------------------------------------------------------------------
alter publication supabase_realtime add table public.orders;
alter publication supabase_realtime add table public.bids;
alter publication supabase_realtime add table public.messages;
alter publication supabase_realtime add table public.notifications;
alter publication supabase_realtime add table public.driver_locations;
-- ملاحظة: إن سبّب السطر الأخير خطأ (الجدول لم يُضَف بعد) احذفه، فالجداول الأربعة الأولى تكفي.

-- ----------------------------------------------------------------------------
-- 13) بيانات أولية للسائقين (اختياري — للمعاينة قبل تسجيل سائقين حقيقيين)
--     هؤلاء سائقون تجريبيون بدون حساب auth؛ يظهر name و rating فقط.
--     يمكنك حذفهم بعد تسجيل سائقين حقيقيين.
-- ----------------------------------------------------------------------------
-- ملاحظة: إذا أردت إضافة سائقين تجريبيين، أنشئ حسابات لهم عبر Supabase Auth
-- ثم حدّث صف profiles لهم بـ role='DRIVER' وبيانات المركبة.

-- ----------------------------------------------------------------------------
-- 14) منح الصلاحيات لـ anon و authenticated
-- ----------------------------------------------------------------------------
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on all tables in schema public to anon, authenticated;
grant select, execute on all functions in schema public to anon, authenticated;

-- ============================================================================
--  انتهى. النتيجة: 6 جداول + 2 دوال + triggers + RLS policies + Realtime.
--  الخطوة التالية: فعّل Phone Auth و Google OAuth من
--  Authentication → Providers في لوحة Supabase.
-- ============================================================================
