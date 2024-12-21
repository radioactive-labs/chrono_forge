require "chrono_forge"

require "minitest/autorun"
require "minitest/reporters"
Minitest::Reporters.use!

require "combustion"
Combustion.path = "test/internal"
Combustion.initialize! :active_record, :active_job
