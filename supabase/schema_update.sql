-- ============================================================
-- Mise à jour du schéma pour l'admin (à lancer APRÈS schema.sql)
-- Supabase > SQL Editor > New query > Run
-- ============================================================

-- e-mail visible dans la liste des élèves
alter table public.profiles add column if not exists email text;
update public.profiles p set email = u.email from auth.users u where u.id = p.id and p.email is null;

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, first_name, last_name, whatsapp, country, email)
  values (new.id,
          new.raw_user_meta_data->>'first_name',
          new.raw_user_meta_data->>'last_name',
          new.raw_user_meta_data->>'whatsapp',
          new.raw_user_meta_data->>'country',
          new.email);
  return new;
end $$;

-- l'admin peut donner/retirer un accès et corriger une commande
create policy "inscriptions admin" on public.enrollments
  for all using (public.is_admin()) with check (public.is_admin());
create policy "commandes admin" on public.orders
  for update using (public.is_admin()) with check (public.is_admin());
