require "test_helper"

class ChronoForgeTest < Minitest::Test
  def test_version
    assert ChronoForge::VERSION
  end
end
