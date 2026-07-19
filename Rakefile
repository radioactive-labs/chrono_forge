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

# The multi-db checks each boot the app with a different ChronoForge database
# configuration, which ChronoForge::ApplicationRecord reads exactly once at
# class load — so every file gets its own process (a shared process would
# re-route the whole suite and the configs would clobber each other). Hooked
# into `test` so CI (appraisal rake test) and the default task run them.
desc "Run the multi-database checks, one process per file"
task "test:multi_db" do
  FileList["test/multi_db/**/*_test.rb"].each do |file|
    ruby "-Itest", file
  end
end
task test: "test:multi_db"

# Release tasks (release:core:*, release:dashboard:*). Loaded after
# bundler/gem_tasks so it can neutralize the bare `rake release` footgun.
Dir.glob(File.expand_path("lib/tasks/*.rake", __dir__)).sort.each { |f| load f }
