# frozen_string_literal: true

class InstallChronoForge < ActiveRecord::Migration[7.1]
  def change
    create_table :chrono_forge_workflows do |t|
      t.string :key, null: false, index: {unique: true}
      t.string :job_klass, null: false

      if t.respond_to?(:jsonb)
        t.jsonb :kwargs, null: false, default: {}
        t.jsonb :options, null: false, default: {}
        t.jsonb :context, null: false, default: {}
      else
        t.json :kwargs, null: false, default: {}
        t.json :options, null: false, default: {}
        t.json :context, null: false, default: {}
      end

      t.integer :state, null: false, default: 0
      t.string :locked_by
      t.datetime :locked_at

      t.datetime :started_at
      t.datetime :completed_at

      t.timestamps
    end

    create_table :chrono_forge_execution_logs do |t|
      t.references :workflow, null: false, foreign_key: {to_table: :chrono_forge_workflows}
      t.string :step_name, null: false
      t.integer :attempts, null: false, default: 0
      t.datetime :started_at
      t.datetime :last_executed_at
      t.datetime :completed_at
      if t.respond_to?(:jsonb)
        t.jsonb :metadata
      else
        t.json :metadata
      end
      t.integer :state, null: false, default: 0
      t.string :error_class
      t.text :error_message

      t.timestamps
      t.index %i[workflow_id step_name], unique: true
    end

    create_table :chrono_forge_error_logs do |t|
      t.references :workflow, null: false, foreign_key: {to_table: :chrono_forge_workflows}
      t.string :error_class
      t.text :error_message
      t.text :backtrace
      if t.respond_to?(:jsonb)
        t.jsonb :context
      else
        t.json :context
      end

      t.timestamps
    end
  end
end
