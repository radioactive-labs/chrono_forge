# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"
require "standard/rake"

task default: %i[test standard]

# https://juincc.medium.com/how-to-setup-minitest-for-your-gems-development-f29c4bee13c2
Rake::TestTask.new do |t|
  t.libs << "test"
  t.test_files = FileList["test/**/*_test.rb"].exclude("test/multi_db/**/*")
  t.verbose = true
end

# The multi-db end-to-end check needs its own TestTask (= its own process): it
# points ChronoForge at a secondary database before the internal app boots,
# which would re-route every other test if it ran inside the main suite.
# Hooked into `test` so CI (appraisal rake test) and the default task run it.
Rake::TestTask.new("test:multi_db") do |t|
  t.libs << "test"
  t.test_files = FileList["test/multi_db/**/*_test.rb"]
  t.verbose = true
end
task test: "test:multi_db"

# Release tasks (release:core:*, release:dashboard:*). Loaded after
# bundler/gem_tasks so it can neutralize the bare `rake release` footgun.
Dir.glob(File.expand_path("lib/tasks/*.rake", __dir__)).sort.each { |f| load f }
