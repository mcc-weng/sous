-- jobs_write only allowed kind in ('chat', 'ritual') — recipe_intake (M2c1's job kind)
-- was never added despite the pipeline going live, because M2c1's own tests and cloud
-- exit check always used the worker's service-role connection (bypasses RLS entirely),
-- never the RLS-bound client path. Same class of bug 0005 fixed for 'ritual': it goes
-- unnoticed until a real client tries to insert one for real. M2c2's share extension
-- is the first thing that ever will.
alter policy jobs_write on jobs
  with check (is_member(household_id) and kind in ('chat', 'ritual', 'recipe_intake'));
