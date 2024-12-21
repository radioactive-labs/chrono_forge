require "test_helper"

class ChronoForgeTest < Minitest::Test
  include ChaoticJob::Helpers

  def test_version
    assert ChronoForge::VERSION
  end

  def test_job_is_durable
    DurableJob.perform_later(:key)
    perform_all_jobs

    assert ChronoForge::Workflow.last.completed?
  end
end
