-- ============================================================================
-- 012_photo_versions.sql: cache-busting numbers for flavor photos and nutrition labels.
--
-- The website adds "?v=<number>" to every flavor photo and nutrition-label URL. A phone that
-- saw the old picture has cached "chimp-chips.jpg?v=1"; "?v=2" is a different URL, so it
-- downloads the new file at once.
--
-- To publish a new photo: replace the file in public/assets/flavors/, deploy, then run
--   update public.flavors set photo_version = photo_version + 1 where slug = 'choc-chip';
-- (for a new nutrition label image, bump nutrition_version the same way).
-- Run after 011.
-- ============================================================================
alter table public.flavors
  add column photo_version     int not null default 1 check (photo_version >= 1),
  add column nutrition_version int not null default 1 check (nutrition_version >= 1);
