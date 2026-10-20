#!/usr/bin/env bash
set -Eeuo pipefail

create_database() {
    local db="$1"
    local user="$2"
    local password="$3"

    echo "Initializing database: ${db}"

    psql -v ON_ERROR_STOP=1 \
        -U "$POSTGRES_USER" \
        -d postgres \
        -v db_name="$db" \
        -v db_user="$user" \
        -v db_password="$password" <<'SQL'

SELECT format(
    'CREATE ROLE %I LOGIN PASSWORD %L',
    :'db_user',
    :'db_password'
)
WHERE NOT EXISTS (
    SELECT 1 FROM pg_roles
    WHERE rolname = :'db_user'
)
\gexec

SELECT format(
    'CREATE DATABASE %I OWNER %I',
    :'db_name',
    :'db_user'
)
WHERE NOT EXISTS (
    SELECT 1 FROM pg_database
    WHERE datname = :'db_name'
)
\gexec

SQL
}

create_database \
    "$JIRA_DB" \
    "$JIRA_DB_USER" \
    "$JIRA_DB_PASSWORD"

create_database \
    "$CONFLUENCE_DB" \
    "$CONFLUENCE_DB_USER" \
    "$CONFLUENCE_DB_PASSWORD"

create_database \
    "$BITBUCKET_DB" \
    "$BITBUCKET_DB_USER" \
    "$BITBUCKET_DB_PASSWORD"

echo "Database initialization complete."
