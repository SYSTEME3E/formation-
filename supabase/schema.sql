-- ============================================================
-- Plateforme de formations Eric Kpakpo : schéma Supabase
-- À coller dans Supabase > SQL Editor > New query > Run
-- ============================================================

create extension if not exists pgcrypto;

-- ---------- CATALOGUE ----------
create table public.categories (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique,
  position int not null default 0
);

create table public.courses (
  id uuid primary key default gen_random_uuid(),
  category_id uuid references public.categories(id) on delete set null,
  title text not null,
  slug text not null unique,
  short_description text,
  description text,
  cover_url text,
  level text not null default 'debutant' check (level in ('debutant','intermediaire','avance')),
  price_xof int not null check (price_xof >= 0),
  old_price_xof int check (old_price_xof >= 0),
  instructor text not null default 'Eric Kpakpo',
  is_published boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.modules (
  id uuid primary key default gen_random_uuid(),
  course_id uuid not null references public.courses(id) on delete cascade,
  title text not null,
  position int not null default 0
);

create table public.lessons (
  id uuid primary key default gen_random_uuid(),
  module_id uuid not null references public.modules(id) on delete cascade,
  course_id uuid not null references public.courses(id) on delete cascade,
  title text not null,
  video_url text,
  content text,
  duration_min int,
  is_free_preview boolean not null default false,
  position int not null default 0
);

-- fichiers à télécharger (stockés dans le bucket privé "course-files")
create table public.lesson_files (
  id uuid primary key default gen_random_uuid(),
  lesson_id uuid references public.lessons(id) on delete cascade,
  course_id uuid not null references public.courses(id) on delete cascade,
  name text not null,
  file_path text not null,            -- ex : <course_id>/guide.pdf
  created_at timestamptz not null default now()
);

-- ---------- ÉLÈVES ----------
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  first_name text,
  last_name text,
  whatsapp text,
  country text,
  created_at timestamptz not null default now()
);

create table public.user_roles (
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('admin')),
  primary key (user_id, role)
);

create table public.lesson_progress (
  user_id uuid not null references auth.users(id) on delete cascade,
  lesson_id uuid not null references public.lessons(id) on delete cascade,
  completed_at timestamptz not null default now(),
  primary key (user_id, lesson_id)
);

-- ---------- VENTES ----------
create table public.promo_codes (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  percent_off int not null check (percent_off between 1 and 100),
  max_uses int,
  used_count int not null default 0,
  expires_at timestamptz,
  is_active boolean not null default true
);

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete set null,
  course_id uuid not null references public.courses(id),
  amount_xof int not null check (amount_xof >= 0),
  promo_code_id uuid references public.promo_codes(id),
  status text not null default 'pending' check (status in ('pending','paid','failed','refunded')),
  kkiapay_transaction_id text unique,
  created_at timestamptz not null default now(),
  paid_at timestamptz
);

create table public.enrollments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  course_id uuid not null references public.courses(id) on delete cascade,
  order_id uuid references public.orders(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (user_id, course_id)
);

create index on public.modules (course_id);
create index on public.lessons (course_id);
create index on public.lessons (module_id);
create index on public.enrollments (user_id);
create index on public.orders (user_id);

-- ---------- FONCTIONS ----------
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.user_roles where user_id = auth.uid() and role = 'admin');
$$;

create or replace function public.has_access(p_course uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select public.is_admin()
      or exists (select 1 from public.enrollments where user_id = auth.uid() and course_id = p_course);
$$;

-- profil créé automatiquement à l'inscription
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, first_name, last_name, whatsapp, country)
  values (new.id,
          new.raw_user_meta_data->>'first_name',
          new.raw_user_meta_data->>'last_name',
          new.raw_user_meta_data->>'whatsapp',
          new.raw_user_meta_data->>'country');
  return new;
end $$;

create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

-- tableau de bord admin
create or replace function public.admin_stats()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return jsonb_build_object(
    'students',    (select count(*) from public.profiles),
    'orders_paid', (select count(*) from public.orders where status = 'paid'),
    'revenue_xof', (select coalesce(sum(amount_xof), 0) from public.orders where status = 'paid')
  );
end $$;
revoke execute on function public.admin_stats() from anon;

-- plan public d'une formation (sans vidéos ni contenu des leçons)
create view public.lesson_outline as
  select l.id, l.module_id, l.course_id, l.title, l.duration_min, l.is_free_preview, l.position
  from public.lessons l
  join public.courses c on c.id = l.course_id
  where c.is_published;
grant select on public.lesson_outline to anon, authenticated;

-- ---------- SÉCURITÉ (RLS) ----------
alter table public.categories      enable row level security;
alter table public.courses         enable row level security;
alter table public.modules         enable row level security;
alter table public.lessons         enable row level security;
alter table public.lesson_files    enable row level security;
alter table public.profiles        enable row level security;
alter table public.user_roles      enable row level security;
alter table public.lesson_progress enable row level security;
alter table public.promo_codes     enable row level security;
alter table public.orders          enable row level security;
alter table public.enrollments     enable row level security;

-- catalogue : lecture publique, écriture admin
create policy "categories lecture"  on public.categories for select using (true);
create policy "categories admin"    on public.categories for all using (public.is_admin()) with check (public.is_admin());

create policy "courses lecture"     on public.courses for select using (is_published or public.is_admin());
create policy "courses admin"       on public.courses for all using (public.is_admin()) with check (public.is_admin());

create policy "modules lecture"     on public.modules for select
  using (public.is_admin() or exists (select 1 from public.courses c where c.id = course_id and c.is_published));
create policy "modules admin"       on public.modules for all using (public.is_admin()) with check (public.is_admin());

-- contenu des leçons : élèves ayant payé, aperçus gratuits, admin
create policy "lessons lecture"     on public.lessons for select
  using (public.is_admin() or public.has_access(course_id)
         or (is_free_preview and exists (select 1 from public.courses c where c.id = course_id and c.is_published)));
create policy "lessons admin"       on public.lessons for all using (public.is_admin()) with check (public.is_admin());

create policy "fichiers lecture"    on public.lesson_files for select using (public.has_access(course_id));
create policy "fichiers admin"      on public.lesson_files for all using (public.is_admin()) with check (public.is_admin());

-- profils : chacun voit et modifie le sien
create policy "profil lecture"      on public.profiles for select using (id = auth.uid() or public.is_admin());
create policy "profil modif"        on public.profiles for update using (id = auth.uid()) with check (id = auth.uid());

-- rôles : lecture du sien uniquement, aucune écriture depuis le site
create policy "role lecture"        on public.user_roles for select using (user_id = auth.uid());

-- progression
create policy "progression lecture" on public.lesson_progress for select using (user_id = auth.uid() or public.is_admin());
create policy "progression ajout"   on public.lesson_progress for insert with check (user_id = auth.uid());
create policy "progression retrait" on public.lesson_progress for delete using (user_id = auth.uid());

-- ventes : lecture seule côté site (écriture par le serveur uniquement)
create policy "commandes lecture"   on public.orders for select using (user_id = auth.uid() or public.is_admin());
create policy "inscriptions lecture" on public.enrollments for select using (user_id = auth.uid() or public.is_admin());
create policy "promos admin"        on public.promo_codes for all using (public.is_admin()) with check (public.is_admin());

-- ---------- STOCKAGE ----------
insert into storage.buckets (id, name, public) values
  ('covers', 'covers', true),
  ('course-files', 'course-files', false)
on conflict (id) do nothing;

create policy "covers admin ecriture" on storage.objects for all
  using (bucket_id = 'covers' and public.is_admin())
  with check (bucket_id = 'covers' and public.is_admin());

create policy "fichiers admin ecriture" on storage.objects for all
  using (bucket_id = 'course-files' and public.is_admin())
  with check (bucket_id = 'course-files' and public.is_admin());

-- un élève peut télécharger les fichiers du dossier <course_id>/ s'il est inscrit
create policy "fichiers eleves lecture" on storage.objects for select
  using (bucket_id = 'course-files' and exists (
    select 1 from public.enrollments e
    where e.user_id = auth.uid() and e.course_id::text = (storage.foldername(name))[1]));

-- ---------- DONNÉES DE DÉPART ----------
insert into public.categories (name, slug, position) values
  ('Marketing digital',      'marketing-digital', 1),
  ('E-commerce',             'e-commerce',        2),
  ('Facebook Ads',           'facebook-ads',      3),
  ('Création de sites web',  'sites-web',         4);

-- ---------- TE PASSER ADMIN ----------
-- 1) Crée d'abord ton compte sur le site. 2) Remplace l'e-mail, puis exécute :
-- insert into public.user_roles (user_id, role)
-- select id, 'admin' from auth.users where email = 'TON_EMAIL@exemple.com';
