require "test_helper"

class ChronoForgeTest < Minitest::Test
  def test_version
    assert ChronoForge::VERSION
  end

  def test_combustion_setup_is_working
    refute ChronoForge::Workflow.exists?
  end
end
