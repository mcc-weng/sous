-- jobs_write only ever allowed kind = 'chat', silently rejecting the M2b2 iOS
-- "開始本週儀式" button's kind = 'ritual' insert under RLS (client insert, not the
-- worker's service-role connection which bypasses RLS entirely). Never exercised
-- until a real-device test actually hit a blank next-week state and tapped the
-- button for real — every prior verification either used an already-locked week
-- (button never shown) or drove the ritual bootstrap via direct DB/job insertion,
-- bypassing this policy. The chat_messages row for the tap succeeds either way
-- (sender = 'user' still satisfies chat_write); only the jobs row silently never
-- gets created, so the brain never runs and the UI is stuck on "chef is thinking".
alter policy jobs_write on jobs
  with check (is_member(household_id) and kind in ('chat', 'ritual'));
