-- plan_weeks.status gains an enforced value set: 'proposing' (ritual mid-flow,
-- the routing signal between chat.md and ritual.md prompts) and 'locked'
-- (finalized week, unchanged default from M1). No existing row can violate
-- this — every row written so far (M1/M2a seeds, real use) used 'locked'.
alter table plan_weeks
  add constraint plan_weeks_status_check check (status in ('proposing', 'locked'));
