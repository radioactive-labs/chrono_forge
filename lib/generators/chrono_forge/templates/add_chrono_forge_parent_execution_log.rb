# frozen_string_literal: true

# Adds chrono_forge_workflows.parent_execution_log_id: the execution log that
# spawned a workflow (for branches, the branch$<name> log). Deliberately generic
# so any future step that spawns sub-workflows can reuse it. The composite
# [parent_execution_log_id, state] index makes the merge completion probe and the
# dropped-job re-kick index-only at hundreds of thousands of children.
#
# Shipped standalone (matching add_chrono_forge_workflow_state_index) so existing
# installs pick it up via `rails generate chrono_forge:upgrade`.
class AddChronoForgeParentExecutionLog < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def change
    add_column :chrono_forge_workflows, :parent_execution_log_id, parent_log_fk_type,
      null: true, if_not_exists: true

    add_index :chrono_forge_workflows, %i[parent_execution_log_id state],
      if_not_exists: true, **chrono_forge_index_algorithm
  end

  private

  # Match the type of chrono_forge_workflows.id so the FK lines up on both bigint
  # and uuid installs.
  def parent_log_fk_type
    id_col = connection.columns(:chrono_forge_workflows).find { |c| c.name == "id" }
    (id_col&.type == :uuid) ? :uuid : :bigint
  end

  def chrono_forge_index_algorithm
    if connection.adapter_name.to_s.downcase.include?("postgresql")
      {algorithm: :concurrently}
    else
      {}
    end
  end
end
