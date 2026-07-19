# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in chrono_forge.gemspec
gemspec

# Floor, not a ~> pin: a fresh resolve pairs the latest Rails with sqlite3 2.x
# (Active Record 8+ requires >= 2.1 — the Postgres CI lane hits this because the
# secondary in-memory `chrono` test database loads the sqlite3 adapter at boot),
# while the locked local bundle and the rails_7.1 appraisal stay on 1.x.
gem "sqlite3", ">= 1.4"

# Only the Postgres CI lane installs this (BUNDLE_WITH=postgres) to run the gem's
# migrations under strong_migrations on PostgreSQL. Default (SQLite) bundles skip it,
# so contributors don't need libpq locally.
group :postgres, optional: true do
  gem "pg"
end
