-- supabase/migrations/0019_cook_photo_storage.sql
-- Pass 1c (Cook Mode redesign): the 上菜 photo-capture column, plus the storage bucket
-- it's uploaded into. Private bucket + household-scoped RLS, mirroring the is_member()
-- pattern every other table's policy already uses (0002_rls.sql), rather than a public
-- bucket. See docs/superpowers/specs/2026-08-07-m3-visual-restyle-pass1c-cook-mode-design.md.

alter table cook_sessions add column photo_url text;

insert into storage.buckets (id, name, public)
values ('cook-photos', 'cook-photos', false)
on conflict (id) do nothing;

-- Objects are stored at "{household_id}/{cook_session_id}.jpg" — the first path segment
-- is the household id, checked against household_members the same way every other
-- table's RLS policy does.
create policy cook_photos_read on storage.objects for select to authenticated
  using (bucket_id = 'cook-photos' and is_member(((storage.foldername(name))[1])::uuid));

create policy cook_photos_write on storage.objects for insert to authenticated
  with check (bucket_id = 'cook-photos' and is_member(((storage.foldername(name))[1])::uuid));

create policy cook_photos_update on storage.objects for update to authenticated
  using (bucket_id = 'cook-photos' and is_member(((storage.foldername(name))[1])::uuid))
  with check (bucket_id = 'cook-photos' and is_member(((storage.foldername(name))[1])::uuid));
