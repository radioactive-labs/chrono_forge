# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"
require "standard/rake"

task default: %i[test standard]

# https://juincc.medium.com/how-to-setup-minitest-for-your-gems-development-f29c4bee13c2
Rake::TestTask.new do |t|
  t.libs << "test"
  t.test_files = FileList["test/**/*_test.rb"]
  t.verbose = true
end
