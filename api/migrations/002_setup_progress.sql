-- 002_setup_progress.sql — where the "setup" percentage lives.
-- Source: plan C in docs/PLANS.md; no master-document section changes shape
-- (DayState.model_progress keeps its 0-99 contract), so the contract is not
-- touched. English comments, same as 001.
--
-- The percentage the player watches while the trajectories are computed used
-- to be derived by counting rows in the trajectory tables. That works only
-- from the process that can see them complete, and it makes GET /state do
-- work it does not otherwise need. Keeping it on the row means:
--
--   * any replica (or a restarted parent) reads the same number from one
--     column -- the forked child owns the update, the reader owns nothing;
--   * a stale child cannot overwrite a day that has moved on, because the
--     UPDATE is guarded on status = 'setup';
--   * the timeout keeps being a function of created_at, never of this column
--     or of a heartbeat: a child that dies leaves the last value it published
--     and the row is still retired after SETUP_TIMEOUT_S.
--
-- NULL means "nothing published yet" (the first publish happens at the first
-- five-step chunk, so the visible value is 0 either way).
ALTER TABLE experiments
  ADD COLUMN IF NOT EXISTS setup_progress SMALLINT
  CHECK (setup_progress IS NULL OR setup_progress BETWEEN 0 AND 99);
