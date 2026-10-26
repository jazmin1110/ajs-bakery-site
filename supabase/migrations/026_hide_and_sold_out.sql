-- ============================================================================
-- 026_hide_and_sold_out.sql: two weekly switches per flavor, set from the admin Menu page.
--
--   flavors.hidden   = true : off the storefront completely (customers can't see or order it).
--                             Use it when a flavor is out for a while, e.g. no ingredients.
--   flavors.sold_out = true : still on the menu, but shows "Sold out" and can't be ordered.
--                             Use it for "not this week" (customers still see it exists).
--
-- Both are different from `active`: active = false is for drafts and retired flavors.
-- A hidden or sold-out flavor stays a menu flavor, so its recipe, costs and sales stay
-- where they are on the admin pages.
--
-- How it's enforced (database, not the browser):
--   * RLS: visitors only read flavors that are active AND not hidden.
--   * flavor_reserved(): a hidden or sold-out flavor has 0 remaining. That one change
--     makes place_order refuse it ("... is sold out"), makes the storefront show
--     "Sold out", and stops it counting toward "cookies left" when picking the Sunday.
--     The admin "Add order" form still warns + lets the admin go over (same as the cap).
--   * flavor_availability() (public) leaves hidden flavors out, so their names don't leak.
--
-- Switch back on = everything goes back to normal, nothing else to undo.
-- Run after 025.
-- ============================================================================

begin;

-- ---- 1. the two switches ---------------------------------------------------------
alter table public.flavors
  add column hidden   boolean not null default false,
  add column sold_out boolean not null default false;

-- ---- 2. visitors don't see hidden flavors ------------------------------------------
drop policy "anyone reads active flavors" on public.flavors;
create policy "anyone reads active flavors" on public.flavors
  for select using (active and not hidden);

-- ---- 3. hidden / sold out = 0 remaining ------------------------------------------
-- Same columns as 007. Only change: remaining is 0 when the flavor is switched off.
-- Hidden flavors are still listed here (place_order looks them up by slug and must
-- find a row with 0 left, not "no row").
create or replace function public.flavor_reserved(p_sunday date)
returns table (flavor_id bigint, slug text, name text, weekly_cap int, reserved int, remaining int)
language sql stable set search_path = ''
as $$
  select f.id, f.slug, f.name, f.weekly_cap,
         coalesce(r.qty, 0)::int,
         case when f.hidden or f.sold_out then 0
              else greatest(f.weekly_cap - coalesce(r.qty, 0), 0) end::int
  from public.flavors f
  left join (
    select i.flavor_id, sum(i.qty) as qty
    from public.order_items i
    join public.orders o on o.id = i.order_id
    where o.sunday_date = p_sunday
      and (o.status = 'paid' or (o.status = 'pending' and o.expires_at > now()))
    group by i.flavor_id
  ) r on r.flavor_id = f.id
  where f.active
  order by f.id
$$;

-- ---- 4. the public availability list skips hidden flavors ------------------------
create or replace function public.flavor_availability()
returns table (sunday_date date, slug text, name text, weekly_cap int, reserved int, remaining int)
language plpgsql stable security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_sunday date := coalesce(public.ordering_sunday(), public.next_order_sunday(now()));
begin
  return query
    select v_sunday, r.slug, r.name, r.weekly_cap, r.reserved, r.remaining
    from public.flavor_reserved(v_sunday) r
    join public.flavors f on f.id = r.flavor_id
    where not f.hidden;
end $$;

-- ---- 5. the admin switch -----------------------------------------------------------
-- Pass null to leave a switch as it is. Only menu flavors (active) can be switched.
create function public.admin_set_flavor_menu(p_slug text, p_hidden boolean default null, p_sold_out boolean default null)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;

  update public.flavors
     set hidden   = coalesce(p_hidden, hidden),
         sold_out = coalesce(p_sold_out, sold_out)
   where slug = p_slug and active;
  if not found then
    raise exception 'Flavor not found on the menu.' using hint = 'flavor_not_found';
  end if;
end $$;

revoke all on function public.admin_set_flavor_menu(text, boolean, boolean) from public, anon, authenticated;
grant execute on function public.admin_set_flavor_menu(text, boolean, boolean) to authenticated;

commit;
