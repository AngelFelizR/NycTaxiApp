-- 001_init.sql — 4 tables for experiments, decisions and the waitlist.
-- Source: master document section 2.2 (kept in sync with it; English comments).

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Participants (lead capture, not authentication)
CREATE TABLE IF NOT EXISTS participants (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email              TEXT UNIQUE,                -- optional, in clear (needed to send the card)
  name               TEXT,                       -- optional, in clear
  marketing_consent  BOOLEAN NOT NULL DEFAULT FALSE,  -- separate checkbox, off by default
  ip_hash            TEXT NOT NULL,              -- SHA-256(IP_HASH_SALT || ip); never a clear IP
  country            TEXT,                       -- 2-letter CF-IPCountry header
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Experiments (one simulated day)
CREATE TABLE IF NOT EXISTS experiments (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  participant_id    UUID REFERENCES participants(id),
  resume_code_hash  TEXT NOT NULL UNIQUE,      -- SHA-256
  share_token       TEXT NOT NULL UNIQUE,      -- 12 chars base64url
  seed              BIGINT NOT NULL,
  seed_is_custom    BOOLEAN NOT NULL DEFAULT FALSE,   -- user-edited seed -> unofficial result
  status            TEXT NOT NULL CHECK (status IN ('setup','in_progress','finished','abandoned')),
  -- Initial conditions
  company           TEXT NOT NULL,
  start_datetime    TIMESTAMPTZ NOT NULL,
  start_location_id INTEGER NOT NULL,
  -- Final results (NULL until finished). Wage = (driver_pay + tips) / shift hours (ADR-025)
  final_user_wage       NUMERIC(10,2),
  final_policy_wage     NUMERIC(10,2),
  final_baseline_wage   NUMERIC(10,2),
  pct_following_policy  NUMERIC(5,2),
  outcome               TEXT CHECK (outcome IN
    ('beat_model','tied_model','beat_baseline','lost_to_baseline','no_rides')),
  user_percentile       NUMERIC(5,2),
  -- Feedback
  feedback_rating   SMALLINT CHECK (feedback_rating BETWEEN 1 AND 5),
  feedback_comment  TEXT,
  feedback_public   BOOLEAN DEFAULT FALSE,
  -- Sharing analytics (persisted by the daily job)
  share_views       INTEGER NOT NULL DEFAULT 0,
  -- Versions
  model_version     TEXT NOT NULL,
  app_version       TEXT NOT NULL,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  finished_at       TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_experiments_participant ON experiments(participant_id);
CREATE INDEX IF NOT EXISTS idx_experiments_status ON experiments(status);
CREATE INDEX IF NOT EXISTS idx_experiments_share_token ON experiments(share_token);

-- Decisions (all trajectories: user, policy, baseline)
CREATE TABLE IF NOT EXISTS decisions (
  experiment_id     UUID NOT NULL REFERENCES experiments(id) ON DELETE CASCADE,
  decision_source   TEXT NOT NULL CHECK (decision_source IN ('user','policy','baseline')),
  step              INTEGER NOT NULL,
  trip_id           BIGINT NOT NULL,
  accepted          BOOLEAN NOT NULL,
  model_recommended BOOLEAN NOT NULL,          -- computed for the 3 sources (always = accepted for 'policy')
  trip_miles        NUMERIC(8,2),
  trip_time         INTEGER,                   -- seconds
  driver_pay        NUMERIC(10,2),
  tips              NUMERIC(10,2),
  pu_location_id    INTEGER,
  do_location_id    INTEGER,
  request_datetime  TIMESTAMPTZ,
  dropoff_datetime  TIMESTAMPTZ,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (experiment_id, decision_source, step)
);

CREATE INDEX IF NOT EXISTS idx_decisions_experiment ON decisions(experiment_id);
CREATE INDEX IF NOT EXISTS idx_decisions_source ON decisions(experiment_id, decision_source);

-- Waitlist for when the app is full (503)
CREATE TABLE IF NOT EXISTS waitlist (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email       TEXT NOT NULL UNIQUE,
  ip_hash     TEXT NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
