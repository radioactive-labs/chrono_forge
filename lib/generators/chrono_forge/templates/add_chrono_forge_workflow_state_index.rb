# frozen_string_literal: true

# Adds a composite [state, completed_at] index to chrono_forge_workflows. This
# supports state-based monitoring (stalled/failed dashboards) and the retention
# scan ChronoForge::Cleanup runs over completed workflows (the high-volume
# terminal state), which filters by completed_at. The state prefix also serves
# the smaller failed-workflow scan.
#
# Shipped as a standalone migration (rather than folded into the install
# migration) so applications created with an earlier version of ChronoForge can
# pick it up via `rails generate chrono_forge:upgrade`.
class AddChronoForgeWorkflowStateIndex < ActiveRecord::Migration[7.1]
  # On PostgreSQL the index is built CONCURRENTLY so it does not lock the table
  # against writes, which also keeps strong_migrations satisfied. Concurrent
  # index builds cannot run inside a transaction.
  disable_ddl_transaction!

  def change
    add_index :chrono_forge_workflows, %i[state completed_at],
      if_not_exists: true,
      **chrono_forge_index_algorithm
  end

  private

  def chrono_forge_index_algorithm
    if connection.adapter_name.to_s.downcase.include?("postgresql")
      {algorithm: :concurrently}
    else
      {}
    end
  end
end
