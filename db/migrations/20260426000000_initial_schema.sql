-- =============================================================================
-- Migration: 20260426000000_initial_schema.sql
-- Description: Initial schema — PostgreSQL extensions, uuid_generate_v7(),
--              updated_at trigger, and core tables.
-- Clauses: CLAUDE.md §3.1 (schema rules), §3.2 (LOINC canonicalization / INV-1),
--          §3.4.2 (enc_ table convention / INV-3)
-- Backfill plan: N/A — initial migration, no pre-existing data.
-- Key-version note: enc_biometric_connections tracks KMS key version per-row
--   in kms_key_version (text). No migration required on key rotation; the
--   rewrap flow updates rotated_at and kms_key_version in-place (§3.4.3).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Extensions (locked stack — CLAUDE.md §2.1)
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ---------------------------------------------------------------------------
-- uuid_generate_v7() — time-ordered UUIDs (§3.1)
-- Preferred over v4 for index locality. Uses pgcrypto gen_random_bytes()
-- for cryptographic randomness in the random bits field.
--
-- Layout (RFC draft-peabody-dispatch-new-uuid-format):
--   bytes 0-5  : 48-bit unix timestamp in ms (big-endian)
--   byte  6    : version nibble (0x7_) | 4 random bits
--   byte  7    : 8 random bits
--   byte  8    : variant bits (0b10xxxxxx) | 6 random bits
--   bytes 9-15 : 56 random bits
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION uuid_generate_v7()
RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
  ts_ms      bigint;
  ts_bytes   bytea;
  rand_bytes bytea;
  uuid_bytes bytea;
BEGIN
  ts_ms      := floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint;
  ts_bytes   := int8send(ts_ms);       -- 8 bytes, big-endian int64
  rand_bytes := gen_random_bytes(10);  -- 10 cryptographically random bytes

  -- Concat: top 6 bytes of timestamp || 10 random bytes = 16 bytes total
  uuid_bytes := substring(ts_bytes FROM 3 FOR 6) || rand_bytes;

  -- Set version nibble = 7 (0111) in high nibble of byte 6
  uuid_bytes := set_byte(uuid_bytes, 6,
    (get_byte(uuid_bytes, 6) & x'0f'::int) | x'70'::int);

  -- Set RFC 4122 variant (10xx) in top 2 bits of byte 8
  uuid_bytes := set_byte(uuid_bytes, 8,
    (get_byte(uuid_bytes, 8) & x'3f'::int) | x'80'::int);

  RETURN encode(uuid_bytes, 'hex')::uuid;
END;
$$;

-- ---------------------------------------------------------------------------
-- set_updated_at() — universal updated_at trigger (§3.1)
-- Applied to every table that carries an updated_at column.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- users — owner-operator identity (INV-7: single-user trust model)
-- No clinical PHI stored directly; downstream tables reference via FK.
-- ---------------------------------------------------------------------------
CREATE TABLE users (
  id           uuid        PRIMARY KEY DEFAULT uuid_generate_v7(),
  email        text        NOT NULL UNIQUE,
  display_name text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  deleted_at   timestamptz
);

CREATE TRIGGER trg_users_updated_at
  BEFORE UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- loinc_codes — canonical LOINC reference table (INV-1, §3.2)
-- Append-only import target; no updated_at trigger (immutable reference data).
-- Every lab_markers.marker_key MUST resolve to a row here.
-- ---------------------------------------------------------------------------
CREATE TABLE loinc_codes (
  loinc_num        text        PRIMARY KEY,
  component        text        NOT NULL,
  property         text        NOT NULL,
  system           text        NOT NULL,
  scale_typ        text        NOT NULL,
  long_common_name text        NOT NULL,
  status           text        NOT NULL
    CHECK (status IN ('ACTIVE', 'TRIAL', 'DISCOURAGED', 'DEPRECATED')),
  imported_at      timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- lab_markers — canonical lab results (INV-1, §3.2)
-- marker_key is a FK to loinc_codes; free-text marker names are forbidden here.
-- Unresolved entries (confidence < 0.85) go to lab_markers_staging instead.
-- ---------------------------------------------------------------------------
CREATE TABLE lab_markers (
  id            uuid        PRIMARY KEY DEFAULT uuid_generate_v7(),
  user_id       uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  marker_key    text        NOT NULL REFERENCES loinc_codes(loinc_num),
  value_numeric numeric,
  value_text    text,
  unit_ucum     text        NOT NULL,
  observed_at   timestamptz NOT NULL,
  source        text        NOT NULL
    CHECK (source IN ('manual', 'quest', 'labcorp', 'dexa', 'imported_pdf')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  deleted_at    timestamptz,
  CHECK (value_numeric IS NOT NULL OR value_text IS NOT NULL)
);

CREATE TRIGGER trg_lab_markers_updated_at
  BEFORE UPDATE ON lab_markers
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_lab_markers_user_id     ON lab_markers(user_id);
CREATE INDEX idx_lab_markers_marker_key  ON lab_markers(marker_key);
CREATE INDEX idx_lab_markers_observed_at ON lab_markers(observed_at DESC)
  WHERE deleted_at IS NULL;

-- ---------------------------------------------------------------------------
-- lab_markers_staging — low-confidence LOINC entries awaiting human review (§3.2)
-- Confidence < 0.85 from the LOINC resolver routes here. Once reviewed and
-- resolved, rows are promoted to lab_markers and soft-deleted from staging.
-- ---------------------------------------------------------------------------
CREATE TABLE lab_markers_staging (
  id               uuid        PRIMARY KEY DEFAULT uuid_generate_v7(),
  user_id          uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  raw_marker_name  text        NOT NULL,
  candidate_loincs jsonb       NOT NULL DEFAULT '[]',
  confidence       numeric     NOT NULL CHECK (confidence >= 0 AND confidence <= 1),
  raw_value        text,
  raw_unit         text,
  observed_at      timestamptz NOT NULL,
  source           text        NOT NULL
    CHECK (source IN ('manual', 'quest', 'labcorp', 'dexa', 'imported_pdf')),
  reviewed_at      timestamptz,
  reviewer_note    text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_lab_markers_staging_updated_at
  BEFORE UPDATE ON lab_markers_staging
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_lab_markers_staging_user_id   ON lab_markers_staging(user_id);
CREATE INDEX idx_lab_markers_staging_unreviewed ON lab_markers_staging(created_at)
  WHERE reviewed_at IS NULL;

-- ---------------------------------------------------------------------------
-- enc_biometric_connections — KMS envelope-encrypted biometric credentials
-- Implements INV-3 and §3.4.2 enc_ table convention.
-- Plaintext OAuth tokens, refresh tokens, and device secrets MUST NOT appear
-- outside the ciphertext column. provider_user_fp is an HMAC fingerprint
-- (separate KMS HMAC key) used for indexed lookups — never the raw provider id.
-- ---------------------------------------------------------------------------
CREATE TABLE enc_biometric_connections (
  id               uuid        PRIMARY KEY DEFAULT uuid_generate_v7(),
  user_id          uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  provider         text        NOT NULL,
  ciphertext       bytea       NOT NULL,
  iv               bytea       NOT NULL,   -- 12-byte AES-GCM IV
  auth_tag         bytea       NOT NULL,   -- 16-byte AES-GCM authentication tag
  encrypted_dek    bytea       NOT NULL,   -- DEK ciphertext from KMS:GenerateDataKey
  kms_key_id       text        NOT NULL,   -- KMS CMK ARN used to wrap the DEK
  kms_key_version  text        NOT NULL,   -- Application-level rotation version label
  provider_user_fp bytea       NOT NULL,   -- HMAC-SHA256 fingerprint for indexed lookup
  created_at       timestamptz NOT NULL DEFAULT now(),
  rotated_at       timestamptz             -- Updated on DEK rewrap during key rotation
);

-- Unique fingerprint index: one connection per (user, provider, identity).
-- Supports O(1) lookup without decrypting any payload.
CREATE UNIQUE INDEX idx_enc_biometric_connections_lookup
  ON enc_biometric_connections(user_id, provider, provider_user_fp);
