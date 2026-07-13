-- Partial unique index backing state_api.add_shopping_item's atomic upsert.
-- Only unchecked rows participate in the dedupe — a checked item and a
-- freshly re-added item with the same name are allowed to coexist.
create unique index shopping_items_household_name_unchecked
  on shopping_items (household_id, lower(name))
  where checked = false;
