require "test_helper"

# The connects_to wiring in ChronoForge::ApplicationRecord runs once at class
# load, before any test here could change the config, so it is covered by the
# dedicated-process tests under test/multi_db/ (rake test:multi_db) — not here.
class ApplicationRecordTest < ActiveJob::TestCase
  def test_models_inherit_from_chrono_forge_application_record
    [ChronoForge::Workflow, ChronoForge::ExecutionLog, ChronoForge::ErrorLog].each do |model|
      assert_equal ChronoForge::ApplicationRecord, model.superclass,
        "#{model} should inherit ChronoForge::ApplicationRecord"
    end
  end

  def test_application_record_is_abstract
    assert ChronoForge::ApplicationRecord.abstract_class?
  end
end
