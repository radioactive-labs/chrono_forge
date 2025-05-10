# ChronoForge

[![Gem Version](https://badge.fury.io/rb/chrono_forge.svg)](https://badge.fury.io/rb/chrono_forge)
[![Ruby](https://github.com/radioactive-labs/chrono_forge/actions/workflows/main.yml/badge.svg)](https://github.com/radioactive-labs/chrono_forge/actions/workflows/main.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)


> A robust framework for building durable, distributed workflows in Ruby on Rails applications

ChronoForge provides a powerful solution for handling long-running processes, managing state, and recovering from failures in your Rails applications. Built on top of ActiveJob, it ensures your critical business processes remain resilient and traceable.

## 🌟 Features

- **Durable Execution**: Automatically tracks and recovers from failures during workflow execution
- **State Management**: Built-in workflow state tracking with persistent context storage
- **Concurrency Control**: Advanced locking mechanisms to prevent parallel execution of the same workflow
- **Error Handling**: Comprehensive error tracking with configurable retry strategies
- **Execution Logging**: Detailed logging of workflow steps and errors for visibility
- **Wait States**: Support for time-based waits and condition-based waiting
- **Database-Backed**: All workflow state is persisted to ensure durability
- **ActiveJob Integration**: Compatible with all ActiveJob backends, though database-backed processors (like Solid Queue) provide the most reliable experience for long-running workflows

## 📦 Installation

Add to your application's Gemfile:

```ruby
gem 'chrono_forge'
```

Then execute:

```bash
$ bundle install
```

Or install directly:

```bash
$ gem install chrono_forge
```

After installation, run the generator to create the necessary database migrations:

```bash
$ rails generate chrono_forge:install
$ rails db:migrate
```

## 📋 Usage

### Creating and Executing Workflows

ChronoForge workflows are ActiveJob classes that prepend the `ChronoForge::Executor` module. Each workflow can **only** accept keyword arguments:

```ruby
# Define your workflow class
class OrderProcessingWorkflow < ApplicationJob
  prepend ChronoForge::Executor
  
  def perform(order_id:, customer_id:)
    # Workflow steps...
  end
end
```

All workflows require a unique identifier when executed. This identifier is used to track and manage the workflow:

```ruby
# Execute the workflow
OrderProcessingWorkflow.perform_later(
  "order-123",                 # Unique workflow key
  order_id: "order-134",       # Custom kwargs
  customer_id: "customer-456"  # More custom kwargs
)
```

### Basic Workflow Example

Here's a complete example of a durable order processing workflow:

```ruby
class OrderProcessingWorkflow < ApplicationJob
  prepend ChronoForge::Executor

  def perform(order_id:)
    @order_id = order_id

    # Context can be used to pass and store data between executions
    context.set_once "execution_id", SecureRandom.hex

    # Wait until payment is confirmed
    wait_until :payment_confirmed?

    # Wait for potential fraud check
    wait 1.minute, :fraud_check_delay

    # Durably execute order processing
    durably_execute :process_order

    # Final steps
    complete_order
  end

  private

  def payment_confirmed?
    PaymentService.confirmed?(@order_id, context["execution_id"])
  end

  def process_order
    OrderProcessor.process(@order_id, context["execution_id"])
    context["processed_at"] = Time.current.iso8601
  end

  def complete_order
    OrderCompletionService.complete(@order_id, context["execution_id"])
    context["completed_at"] = Time.current.iso8601
  end
end
```

### Core Workflow Features

#### 🚀 Executing Workflows

ChronoForge workflows are executed through ActiveJob's standard interface with a specific parameter structure:

```ruby
# Perform the workflow immediately
OrderProcessingWorkflow.perform_now(
  "order-123",                     # Unique workflow key
  order_id: "O-123",               # Custom parameter
  customer_id: "C-456"             # Another custom parameter
)

# Or queue it for background processing
OrderProcessingWorkflow.perform_later(
  "order-123-async",               # Unique workflow key
  order_id: "O-124",
  customer_id: "C-457"
)
```

**Important:** Workflows must use keyword arguments only, not positional arguments.

#### ⚡ Durable Execution

The `durably_execute` method ensures operations are executed exactly once, even if the job fails and is retried:

```ruby
# Execute a method
durably_execute(:process_payment, max_attempts: 3)

# Or with a block
durably_execute -> (ctx) {
  Payment.process(ctx[:payment_id])
}
```

#### ⏱️ Wait States

ChronoForge supports both time-based and condition-based waits:

```ruby
# Wait for a specific duration
wait 1.hour, :cooling_period

# Wait until a condition is met
wait_until :payment_processed, 
  timeout: 1.hour,
  check_interval: 5.minutes
```

#### 🔄 Workflow Context

ChronoForge provides a persistent context that survives job restarts. The context behaves like a Hash but with additional capabilities:

```ruby
# Set context values
context[:user_name] = "John Doe"
context[:status] = "processing"

# Read context values
user_name = context[:user_name]

# Using the fetch method (returns default if key doesn't exist)
status = context.fetch(:status, "pending")

# Set a value with the set method (alias for []=)
context.set(:total_amount, 99.99)

# Set a value only if the key doesn't already exist
context.set_once(:created_at, Time.current.iso8601)

# Check if a key exists
if context.key?(:user_id)
  # Do something with the user ID
end
```

The context supports serializable Ruby objects (Hash, Array, String, Integer, Float, Boolean, and nil) and validates types automatically.

### 🛡️ Error Handling

ChronoForge automatically tracks errors and provides configurable retry capabilities:

```ruby
class MyWorkflow < ApplicationJob
  prepend ChronoForge::Executor

  private

  def should_retry?(error, attempt_count)
    case error
    when NetworkError
      attempt_count < 5  # Retry network errors up to 5 times
    when ValidationError
      false  # Don't retry validation errors
    else
      attempt_count < 3  # Default retry policy
    end
  end
end
```

## 🧪 Testing

ChronoForge is designed to be easily testable using [ChaoticJob](https://github.com/fractaledmind/chaotic_job), a testing framework that makes it simple to test complex job workflows:

1. Add ChaoticJob to your Gemfile's test group:

```ruby
group :test do
  gem 'chaotic_job'
end
```

2. Set up your test helper:

```ruby
# test_helper.rb
require 'chrono_forge'
require 'minitest/autorun'
require 'chaotic_job'
```

Example test:

```ruby
class WorkflowTest < ActiveJob::TestCase
  include ChaoticJob::Helpers

  def test_workflow_completion
    # Enqueue the job with a unique key and custom parameters
    OrderProcessingWorkflow.perform_later(
      "order-test-123",
      order_id: "O-123",
      customer_id: "C-456"
    )
    
    # Perform all enqueued jobs
    perform_all_jobs
    
    # Assert workflow completed successfully
    workflow = ChronoForge::Workflow.find_by(key: "order-test-123")
    assert workflow.completed?
    
    # Check workflow context
    assert workflow.context["processed_at"].present?
    assert workflow.context["completed_at"].present?
  end
end
```

## 🗄️ Database Schema

ChronoForge creates three main tables:

1. **chrono_forge_workflows**: Stores workflow state and context
2. **chrono_forge_execution_logs**: Tracks individual execution steps
3. **chrono_forge_error_logs**: Records detailed error information

## 🔍 When to Use ChronoForge

ChronoForge is ideal for:

- **Long-running business processes** - Order processing, account registration flows
- **Processes requiring durability** - Financial transactions, data migrations
- **Multi-step workflows** - Onboarding flows, approval processes, multi-stage jobs
- **State machines with time-based transitions** - Document approval, subscription lifecycle

## 🧠 Advanced State Management

ChronoForge workflows follow a sophisticated state machine model to ensure durability and fault tolerance. Understanding these states and transitions is essential for troubleshooting and recovery.

### Workflow State Diagram

```mermaid
stateDiagram-v2
    [*] --> created: Workflow Created
    created --> idle: Initial State
    idle --> running: Job Started
    running --> idle: Waiting
    running --> completed: All Steps Completed
    running --> failed: Max Retries Exhausted
    running --> stalled: Unrecoverable Error
    idle --> running: Resumed
    stalled --> [*]: Requires Manual Intervention
    failed --> [*]: Requires Manual Intervention
    completed --> [*]: Workflow Succeeded
```

### State Descriptions

#### Created
- **Description**: Initial state when a workflow record is first created
- **Behavior**: Transitions immediately to idle state
- **Duration**: Momentary

#### Idle
- **Description**: The workflow is waiting to be processed or between processing steps
- **Behavior**: Not locked, available to be picked up by job processor
- **Duration**: Can be minutes to days, depending on wait conditions

#### Running
- **Description**: The workflow is actively being processed
- **Identifiers**: Has locked_at and locked_by values set
- **Behavior**: Protected against concurrent execution
- **Duration**: Should be brief unless performing long operations

#### Completed
- **Description**: The workflow has successfully executed all steps
- **Identifiers**: Has completed_at timestamp, state = "completed"
- **Behavior**: Final state, no further processing
- **Typical Exit Points**: All processing completed successfully

#### Failed
- **Description**: The workflow has failed after exhausting retry attempts
- **Identifiers**: Has failure-related data in error_logs, state = "failed"
- **Behavior**: No automatic recovery, requires manual intervention
- **Typical Exit Points**: Max retries exhausted, explicit failure, non-retryable error

#### Stalled
- **Description**: The workflow encountered an unrecoverable error but wasn't explicitly failed
- **Identifiers**: Not completed, not running, has errors in error_logs
- **Behavior**: Requires manual investigation and intervention
- **Typical Exit Points**: ExecutionFailedError, unexpected exceptions, system failures

### Handling Different Workflow States

#### Recovering Stalled/Failed Workflows

```ruby
workflow = ChronoForge::Workflow.find_by(key: "order-123")

if workflow.stalled? || workflow.failed?
  job_class = workflow.job_class.constantize
  
  # Retry immediately
  job_class.retry_now(workflow.key)
  
  # Or retry asynchronously
  job_class.retry_later(workflow.key)
end
```

#### Monitoring Running Workflows

Long-running workflows might indicate issues:

```ruby
# Find workflows running for too long
long_running = ChronoForge::Workflow.where(state: :running)
                                   .where('locked_at < ?', 30.minutes.ago)

long_running.each do |workflow|
  # Log potential issues for investigation
  Rails.logger.warn "Workflow #{workflow.key} has been running for >30 minutes"
  
  # Optionally force unlock if you suspect deadlock
  # CAUTION: Only do this if you're certain the job is stuck
  # workflow.update!(locked_at: nil, locked_by: nil, state: :idle)
end
```

## 🚀 Development

After checking out the repo, run:

```bash
$ bin/setup                 # Install dependencies
$ bundle exec rake test     # Run the tests
$ bin/appraise              # Run the full suite of appraisals
$ bin/console               # Start an interactive console
```

The test suite uses SQLite by default and includes:
- Unit tests for core functionality
- Integration tests with ActiveJob
- Example workflow implementations

## 👥 Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin feature/my-new-feature`)
5. Create a new Pull Request

Please include tests for any new features or bug fixes.

## 📜 License

This gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
