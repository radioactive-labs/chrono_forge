require "test_helper"

# Step names use "$" as a reserved separator (e.g. "durably_repeat$name$ts").
# A user-supplied name/method containing "$" would corrupt that scheme (and the
# cleanup logic that parses it), so it must be rejected.
class StepNameValidationTest < ActiveJob::TestCase
  include ChaoticJob::Helpers

  def setup
    ChronoForge::Workflow.destroy_all
  end

  def build_job(&perform_body)
    klass = Class.new(WorkflowJob) do
      prepend ChronoForge::Executor
      define_method(:perform, &perform_body)
      def noop
      end

      def ready?
        true
      end
    end
    Object.const_set(:"BadStepNameWorkflow#{SecureRandom.hex(4)}", klass)
  end

  def test_durably_execute_rejects_name_with_delimiter
    job = build_job { durably_execute :noop, name: "bad$name" }
    assert_raises(ChronoForge::Executor::InvalidStepName) do
      job.perform_now("k-#{SecureRandom.hex(4)}")
    end
  end

  def test_durably_repeat_rejects_name_with_delimiter
    job = build_job { durably_repeat :noop, every: 1.hour, till: :ready?, name: "a$b" }
    assert_raises(ChronoForge::Executor::InvalidStepName) do
      job.perform_now("k-#{SecureRandom.hex(4)}")
    end
  end

  def test_wait_rejects_name_with_delimiter
    job = build_job { wait 1.second, "cool$down" }
    assert_raises(ChronoForge::Executor::InvalidStepName) do
      job.perform_now("k-#{SecureRandom.hex(4)}")
    end
  end

  def test_valid_names_are_accepted
    job = build_job { durably_execute :noop, name: "valid_name" }
    assert_nothing_raised do
      job.perform_now("k-#{SecureRandom.hex(4)}")
    end
  end
end
