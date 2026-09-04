#!/bin/bash
# Create the second database MAS needs, alongside Synapse's.
#
# Runs ONLY on first initialization of an empty data directory — Postgres
# ignores /docker-entrypoint-initdb.d entirely once the cluster exists. If you
# add this to an already-initialized matrix-db, create the database by hand:
#   docker compose exec matrix-db psql -U synapse -c 'CREATE DATABASE mas OWNER synapse;'
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
	CREATE DATABASE mas OWNER $POSTGRES_USER;
EOSQL
