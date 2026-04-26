-- =============================================================================
-- Down Migration: 20260426000000_initial_schema.down.sql
-- Reverses:       20260426000000_initial_schema.sql
-- WARNING: Destroys all data in these tables. Only run in non-production
--          environments or as part of a full teardown procedure.
-- =============================================================================

-- Drop tables in dependency order (FKs resolved bottom-up)
DROP TABLE IF EXISTS enc_biometric_connections CASCADE;
DROP TABLE IF EXISTS lab_markers_staging CASCADE;
DROP TABLE IF EXISTS lab_markers CASCADE;
DROP TABLE IF EXISTS loinc_codes CASCADE;
DROP TABLE IF EXISTS users CASCADE;

-- Drop shared functions
DROP FUNCTION IF EXISTS set_updated_at() CASCADE;
DROP FUNCTION IF EXISTS uuid_generate_v7() CASCADE;

-- NOTE: Extensions (uuid-ossp, pgcrypto) are intentionally left in place.
-- Dropping shared extensions can break unrelated schemas in the same cluster.
-- Remove manually if a complete environment teardown is required.
