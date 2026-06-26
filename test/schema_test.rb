require "test_helper"

class SchemaTest < ActiveJob::TestCase
  def connection
    ChronoForge::Workflow.connection
  end

  def test_workflows_have_state_completed_at_index
    assert connection.index_exists?(:chrono_forge_workflows, %i[state completed_at]),
      "expected a composite index on chrono_forge_workflows [state, completed_at] " \
      "to support monitoring and the completed-workflow retention cleanup scan"
  end

  def test_workflows_have_parent_execution_log_id_column
    assert connection.column_exists?(:chrono_forge_workflows, :parent_execution_log_id),
      "expected chrono_forge_workflows.parent_execution_log_id for branch children"
  end

  def test_workflows_have_parent_execution_log_state_index
    assert connection.index_exists?(:chrono_forge_workflows, %i[parent_execution_log_id state]),
      "expected composite index on [parent_execution_log_id, state] for the merge probe"
  end
end
