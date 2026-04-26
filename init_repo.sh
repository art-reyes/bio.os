#!/usr/bin/env bash
# Builds the bio.os directory structure defined in CLAUDE.md §6.
# Run from the repository root: bash init_repo.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
echo "Initializing bio.os directory structure at: $ROOT"

# app/ — Expo managed-workflow application
mkdir -p "$ROOT/app/(routes)"
mkdir -p "$ROOT/app/ui/icons"
mkdir -p "$ROOT/app/theme"
mkdir -p "$ROOT/app/state"
mkdir -p "$ROOT/app/storage"
mkdir -p "$ROOT/app/api"
mkdir -p "$ROOT/app/config"
mkdir -p "$ROOT/app/lib"

# server/ — Backend services
mkdir -p "$ROOT/server/scheduling"
mkdir -p "$ROOT/server/loinc"
mkdir -p "$ROOT/server/crypto"
mkdir -p "$ROOT/server/api"
mkdir -p "$ROOT/server/config"

# db/ — Append-only migrations and seed data
mkdir -p "$ROOT/db/migrations"
mkdir -p "$ROOT/db/seeds"

# docs/ — ADRs and design specifications
mkdir -p "$ROOT/docs/adr"
mkdir -p "$ROOT/docs/design"

# Ensure empty directories are tracked by git
find "$ROOT/app" "$ROOT/server" "$ROOT/db" "$ROOT/docs" \
  -type d -empty -exec touch {}/.gitkeep \;

echo "Done. All directories created."
