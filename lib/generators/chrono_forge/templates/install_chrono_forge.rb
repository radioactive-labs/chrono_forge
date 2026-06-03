# frozen_string_literal: true

class InstallChronoForge < ActiveRecord::Migration[7.1]
  def change
    create_table :chrono_forge_workflows, id: primary_key_type do |t|
      t.string :key, null: false, index: true
      t.string :job_class, null: false

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
      t.index %i[job_class key], unique: true
    end

    create_table :chrono_forge_execution_logs, id: primary_key_type do |t|
      t.references :workflow, null: false,
        foreign_key: {to_table: :chrono_forge_workflows},
        type: primary_key_type

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

    create_table :chrono_forge_error_logs, id: primary_key_type do |t|
      t.references :workflow, null: false,
        foreign_key: {to_table: :chrono_forge_workflows},
        type: primary_key_type

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

  private

  def primary_key_type
    # Check if the application is configured to use UUIDs
    if ActiveRecord.respond_to?(:default_id) && ActiveRecord.default_id.respond_to?(:to_s) &&
        ActiveRecord.default_id.to_s.include?("uuid")
      return :uuid
    end

    # Rails 6+ configuration style
    if ActiveRecord.respond_to?(:primary_key_type) &&
        ActiveRecord.primary_key_type.to_s == "uuid"
      return :uuid
    end

    # Check application config
    app_config = Rails.application.config.generators
    if app_config.options.key?(:active_record) &&
        app_config.options[:active_record].key?(:primary_key_type) &&
        app_config.options[:active_record][:primary_key_type].to_s == "uuid"
      return :uuid
    end

    # Default to traditional integer keys
    :bigint
  end
end
