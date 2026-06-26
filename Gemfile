# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in chrono_forge.gemspec
gemspec

gem "sqlite3", "~> 1.4"

# Only the Postgres CI lane installs this (BUNDLE_WITH=postgres) to run the gem's
# migrations under strong_migrations on PostgreSQL. Default (SQLite) bundles skip it,
# so contributors don't need libpq locally.
group :postgres, optional: true do
  gem "pg"
end
