#!/usr/bin/env python3
"""Rebuilds supabase/seed_content.sql from flavor-content.json (repo root).

Run from the repo root after editing the JSON:   python3 supabase/build_seed_content.py
The words and numbers are copied exactly. Keys that start with an underscore ("_readme", "_calc"...)
and the "verify" lists are NOT put in the database; the verify lists are printed as a checklist at the end.
"""
import json, pathlib

root = pathlib.Path(__file__).resolve().parent.parent
data = json.loads((root / "flavor-content.json").read_text())

# The JSON's slugs -> the slugs already in the database (orders and saved carts use those, so they stay)
DB_SLUG = {"chimp-chips": "choc-chip", "coco-loco": "double-choc", "bueno-mucho": "kinder-bueno"}

def q(text):                      # a text value, dollar-quoted so no character needs escaping
    assert "$c$" not in text
    return f"$c${text}$c$"

def arr(items):
    return "array[" + ", ".join(q(i) for i in items) + "]::text[]"

out = ["-- ============================================================================",
       "-- seed_content.sql: flavor content, GENERATED from flavor-content.json by supabase/build_seed_content.py.",
       "-- Do not edit by hand: edit the JSON and run the script again.",
       "-- Safe to run more than once. Photos (photo_url, focus_x, focus_y, photo_version) are never touched.",
       "-- Run after migration 013.",
       "-- ============================================================================", ""]

out.append("insert into public.site_settings (key, value) values")
out.append(f"  ('global_allergen_note', {q(data['global_allergen_note'])}),")
out.append(f"  ('nutrition_note', {q(data['nutrition_note'])})")
out.append("on conflict (key) do update set value = excluded.value;\n")

for f in data["flavors"]:
    slugs = sorted({f["slug"], DB_SLUG.get(f["slug"], f["slug"])})
    where = "slug in (" + ", ".join(f"'{s}'" for s in slugs) + ")"
    out.append(f"-- {f['name']}")
    out.append("update public.flavors set")
    out.append(f"  short_description = {q(f['short_description'])},")
    out.append(f"  long_description  = {q(f['long_description'])},")
    out.append(f"  taste_notes       = {arr(f['taste_notes'])},")
    out.append(f"  ingredients       = {q(f['ingredients'])},")
    out.append(f"  contains          = {arr(f['contains'])},")
    out.append(f"  may_contain       = {arr(f['may_contain'])},")
    out.append(f"  weight_label      = {q(f['weight_label'])},")
    out.append(f"  shelf_life        = {q(f['shelf_life'])},")
    out.append(f"  storage_tip       = {q(f['storage_tip'])},")
    out.append(f"  nutrition         = {q(json.dumps(f['nutrition']))}::jsonb")
    out.append(f"where {where};")
    out.append("")

# What you still have to check, printed when the file runs
out.append("do $todo$ begin")
out.append("  raise notice '=== TODO: things to verify before launch (from flavor-content.json) ===';")
for f in data["flavors"]:
    out.append(f"  raise notice '%', {q(f['name'].upper() + ':')};")
    for v in f["verify"]:
        out.append(f"  raise notice '%', {q('  [ ] ' + v)};")
out.append("end $todo$;")

(root / "supabase" / "seed_content.sql").write_text("\n".join(out) + "\n")
print("wrote supabase/seed_content.sql")
