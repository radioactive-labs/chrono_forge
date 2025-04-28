# ChronoForge

![Version](https://img.shields.io/badge/version-0.3.0-blue.svg)
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

### Basic Workflow Example

Here's a complete example of a durable order processing workflow:

```ruby
class OrderProcessingWorkflow < ApplicationJob
  include ChronoForge::Executor

  def perform
    # Context can be used to pass and store data between executions
    context.set_once "order_id", SecureRandom.hex

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
    PaymentService.confirmed?(context["order_id"])
  end

  def process_order
    OrderProcessor.process(context["order_id"])
    context["processed_at"] = Time.current.iso8601
  end

  def complete_order
    OrderCompletionService.complete(context["order_id"])
    context["completed_at"] = Time.current.iso8601
  end
end
```

### Core Workflow Features

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

### 🛡️ Error Handling

ChronoForge automatically tracks errors and provides configurable retry capabilities:

```ruby
class MyWorkflow < ApplicationJob
  include ChronoForge::Executor

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
    # Enqueue the job
    OrderProcessingWorkflow.perform_later("order_123")
    
    # Perform all enqueued jobs
    perform_all_jobs
    
    # Assert workflow completed successfully
    workflow = ChronoForge::Workflow.last
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
