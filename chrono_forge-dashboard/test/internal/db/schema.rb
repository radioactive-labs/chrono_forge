ActiveRecord::Schema.define do
  create_table :chrono_forge_workflows do |t|
    t.string :key, null: false
    t.string :job_class, null: false
    t.integer :state, default: 0, null: false
    t.json :context, null: false, default: {}
    t.json :kwargs, null: false, default: {}
    t.json :options, null: false, default: {}
    t.datetime :locked_at
    t.string :locked_by
    t.datetime :started_at
    t.datetime :completed_at
    t.timestamps
    t.index :key, unique: true
    t.index %i[state completed_at]
  end

  create_table :chrono_forge_execution_logs do |t|
    t.references :workflow, null: false
    t.string :step_name, null: false
    t.integer :attempts, default: 0, null: false
    t.integer :state, default: 0, null: false
    t.datetime :started_at
    t.datetime :completed_at
    t.datetime :last_executed_at
    t.string :error_class
    t.text :error_message
    t.json :metadata
    t.timestamps
    t.index %i[workflow_id step_name], unique: true
  end

  create_table :chrono_forge_error_logs do |t|
    t.references :workflow, null: false
    t.string :step_name
    t.integer :attempt
    t.string :error_class
    t.text :error_message
    t.text :backtrace
    t.json :context
    t.timestamps
  end
end
