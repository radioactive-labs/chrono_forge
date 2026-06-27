# ChronoForge Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A mountable, zero-build Rails engine gem `chrono_forge-dashboard` giving full visibility and operational control over ChronoForge workflows.

**Architecture:** A namespace-isolated Rails engine in a monorepo subfolder with its own gemspec depending on `chrono_forge`. Reuses the core models read-only via query objects and presenters; server-rendered ERB with one engine-served CSS and one vanilla JS file (no build step); fail-closed pluggable auth.

**Tech Stack:** Ruby, Rails (railties/actionpack/activerecord), Zeitwerk, Minitest + Combustion (dummy app), standardrb.

**User Verification:** NO — internal tooling; correctness is covered by controller/query/presenter tests. (Visual polish is iterated separately via the frontend-design skill, not gated here.)

**Working directory:** all paths are relative to the repo root; the dashboard gem lives under `chrono_forge-dashboard/`. Tests run from that subdir: `cd chrono_forge-dashboard && bundle exec rake test`.

---

## File structure

```
chrono_forge.gemspec                         # MODIFY: exclude chrono_forge-dashboard/ from spec.files
chrono_forge-dashboard/
  chrono_forge-dashboard.gemspec
  Gemfile                                     # path "..", gemspec
  Rakefile                                    # Minitest test task
  lib/chrono_forge/dashboard.rb               # entry: requires + Configuration accessor
  lib/chrono_forge/dashboard/version.rb
  lib/chrono_forge/dashboard/configuration.rb
  lib/chrono_forge/dashboard/engine.rb
  lib/chrono_forge/dashboard/step_name_parser.rb
  config/routes.rb
  app/controllers/chrono_forge/dashboard/base_controller.rb
  app/controllers/chrono_forge/dashboard/workflows_controller.rb
  app/controllers/chrono_forge/dashboard/wait_states_controller.rb
  app/controllers/chrono_forge/dashboard/actions_controller.rb
  app/controllers/chrono_forge/dashboard/assets_controller.rb
  app/queries/chrono_forge/dashboard/workflows_query.rb
  app/queries/chrono_forge/dashboard/stats_query.rb
  app/presenters/chrono_forge/dashboard/timeline_presenter.rb
  app/presenters/chrono_forge/dashboard/context_presenter.rb
  app/presenters/chrono_forge/dashboard/periodic_health_presenter.rb
  app/presenters/chrono_forge/dashboard/wait_state_presenter.rb
  app/assets/chrono_forge/dashboard/dashboard.css
  app/assets/chrono_forge/dashboard/dashboard.js
  app/views/layouts/chrono_forge/dashboard/application.html.erb
  app/views/chrono_forge/dashboard/workflows/{index,show}.html.erb + partials
  app/views/chrono_forge/dashboard/wait_states/index.html.erb
  test/test_helper.rb
  test/internal/                              # Combustion dummy app mounting the engine
  test/**/*_test.rb
```

Each task below produces a committed, independently testable unit.

---

### Task 1: Engine skeleton, gemspec, core exclusion, test harness

**Goal:** A loadable, mountable engine with a Combustion dummy app and a passing smoke test; core gem excludes the dashboard dir.

**Files:**
- Modify: `chrono_forge.gemspec:29`
- Create: `chrono_forge-dashboard/chrono_forge-dashboard.gemspec`, `Gemfile`, `Rakefile`, `lib/chrono_forge/dashboard.rb`, `lib/chrono_forge/dashboard/version.rb`, `lib/chrono_forge/dashboard/engine.rb`, `config/routes.rb`
- Create test harness: `chrono_forge-dashboard/test/test_helper.rb`, `test/internal/config/{database.yml,routes.rb}`, `test/internal/db/schema.rb`, `test/smoke_test.rb`

**Acceptance Criteria:**
- [ ] `chrono_forge` gemspec no longer ships `chrono_forge-dashboard/` (excluded from `spec.files`)
- [ ] `ChronoForge::Dashboard::Engine` loads and isolates the `ChronoForge::Dashboard` namespace
- [ ] A request to the mounted engine root renders (smoke test green)

**Verify:** `cd chrono_forge-dashboard && bundle exec rake test` → smoke test passes

**Steps:**

- [ ] **Step 1: Exclude dashboard dir from the core gem**

In `chrono_forge.gemspec`, line 29, add `chrono_forge-dashboard/` to the reject prefixes:

```ruby
        f.start_with?(*%w[bin/ test/ spec/ features/ .git .github appveyor Gemfile chrono_forge-dashboard/])
```

- [ ] **Step 2: Gem metadata files**

`chrono_forge-dashboard/lib/chrono_forge/dashboard/version.rb`:

```ruby
module ChronoForge
  module Dashboard
    VERSION = "0.1.0"
  end
end
```

`chrono_forge-dashboard/chrono_forge-dashboard.gemspec`:

```ruby
require_relative "lib/chrono_forge/dashboard/version"

Gem::Specification.new do |spec|
  spec.name = "chrono_forge-dashboard"
  spec.version = ChronoForge::Dashboard::VERSION
  spec.authors = ["Stefan Froelich"]
  spec.email = ["sfroelich01@gmail.com"]
  spec.summary = "A mountable Rails dashboard for ChronoForge workflows"
  spec.description = "Visibility and operational controls for ChronoForge: workflow list, step replay timeline, context inspector, periodic-task health, wait-state age, and recovery actions."
  spec.homepage = "https://github.com/radioactive-labs/chrono_forge"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.2"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  spec.files = Dir["lib/**/*", "app/**/*", "config/**/*", "MIT-LICENSE", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "chrono_forge"
  spec.add_dependency "railties", ">= 7.1"
  spec.add_dependency "actionpack", ">= 7.1"

  spec.add_development_dependency "rake"
  spec.add_development_dependency "minitest"
  spec.add_development_dependency "minitest-reporters"
  spec.add_development_dependency "combustion"
  spec.add_development_dependency "rack-test"
  spec.add_development_dependency "sqlite3", "~> 1.4"
  spec.add_development_dependency "standard"
end
```

`chrono_forge-dashboard/Gemfile`:

```ruby
source "https://rubygems.org"
gemspec
gem "chrono_forge", path: ".."
```

`chrono_forge-dashboard/Rakefile`:

```ruby
require "rake/testtask"
require "standard/rake"

Rake::TestTask.new do |t|
  t.libs << "test"
  t.test_files = FileList["test/**/*_test.rb"]
  t.verbose = true
end

task default: %i[test standard]
```

- [ ] **Step 3: Engine + entry + routes**

`chrono_forge-dashboard/lib/chrono_forge/dashboard/engine.rb`:

```ruby
require "rails/engine"

module ChronoForge
  module Dashboard
    class Engine < ::Rails::Engine
      isolate_namespace ChronoForge::Dashboard

      # Engine paths are Zeitwerk-loaded by Rails; nothing else needed here.
    end
  end
end
```

`chrono_forge-dashboard/lib/chrono_forge/dashboard.rb`:

```ruby
require "chrono_forge"
require "chrono_forge/dashboard/version"
require "chrono_forge/dashboard/engine"

module ChronoForge
  module Dashboard
  end
end
```

`chrono_forge-dashboard/config/routes.rb`:

```ruby
ChronoForge::Dashboard::Engine.routes.draw do
  root to: "workflows#index"
  resources :workflows, only: %i[index show]
  resources :wait_states, only: :index
  # actions and assets added in later tasks
end
```

`chrono_forge-dashboard/app/controllers/chrono_forge/dashboard/workflows_controller.rb` (stub for the smoke test; fleshed out in Tasks 5/7):

```ruby
module ChronoForge
  module Dashboard
    class WorkflowsController < ActionController::Base
      def index
        render plain: "ChronoForge Dashboard"
      end
    end
  end
end
```

- [ ] **Step 4: Test harness (Combustion dummy mounting the engine)**

`chrono_forge-dashboard/test/internal/config/database.yml`:

```yaml
test:
  adapter: sqlite3
  database: test/internal/db/combustion_test.sqlite
```

`chrono_forge-dashboard/test/internal/config/routes.rb`:

```ruby
Rails.application.routes.draw do
  mount ChronoForge::Dashboard::Engine => "/chrono_forge"
end
```

`chrono_forge-dashboard/test/internal/db/schema.rb` — reuse the core's three tables (copy from the core install migration: `chrono_forge_workflows`, `chrono_forge_execution_logs`, `chrono_forge_error_logs` with all columns incl. `locked_by`, `metadata`, `step_name`, `attempt`/`attempts`):

```ruby
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
```

`chrono_forge-dashboard/test/test_helper.rb`:

```ruby
require "chrono_forge/dashboard"
require "minitest/autorun"
require "minitest/reporters"
Minitest::Reporters.use!

require "combustion"
Combustion.path = "test/internal"
Combustion.initialize! :active_record, :action_controller

require "rails/test_help"
require "rack/test"

module DashboardTestHelpers
  # Create a workflow row with sensible defaults.
  def create_workflow(key:, state: :idle, job_class: "OrderWorkflow", **attrs)
    ChronoForge::Workflow.create!(
      key: key, job_class: job_class, state: ChronoForge::Workflow.states[state],
      context: {}, kwargs: {}, options: {}, started_at: Time.current, **attrs
    )
  end
end
```

`chrono_forge-dashboard/test/smoke_test.rb`:

```ruby
require "test_helper"

class SmokeTest < ActionDispatch::IntegrationTest
  test "engine root renders" do
    get "/chrono_forge"
    assert_response :success
    assert_match "ChronoForge Dashboard", response.body
  end
end
```

- [ ] **Step 5: Install + run**

```bash
cd chrono_forge-dashboard && bundle install && bundle exec rake test
```
Expected: smoke test passes (1 run, 0 failures). If the core gem isn't found, confirm the `gem "chrono_forge", path: ".."` line.

- [ ] **Step 6: Commit**

```bash
git add chrono_forge.gemspec chrono_forge-dashboard
git commit -m "feat(dashboard): engine skeleton, gemspec, and Combustion test harness"
```

```json:metadata
{"files": ["chrono_forge.gemspec", "chrono_forge-dashboard/chrono_forge-dashboard.gemspec", "chrono_forge-dashboard/lib/chrono_forge/dashboard.rb", "chrono_forge-dashboard/lib/chrono_forge/dashboard/engine.rb", "chrono_forge-dashboard/config/routes.rb", "chrono_forge-dashboard/test/test_helper.rb", "chrono_forge-dashboard/test/internal/db/schema.rb", "chrono_forge-dashboard/test/smoke_test.rb"], "verifyCommand": "cd chrono_forge-dashboard && bundle exec rake test", "acceptanceCriteria": ["core gemspec excludes chrono_forge-dashboard/", "engine loads + isolates namespace", "smoke test green"], "requiresUserVerification": false}
```

---

### Task 2: Configuration + fail-closed auth

**Goal:** `ChronoForge::Dashboard` config object and a `BaseController` whose `authenticate!` resolves hook → http_basic → `:none` → raise.

**Files:**
- Create: `lib/chrono_forge/dashboard/configuration.rb`, `app/controllers/chrono_forge/dashboard/base_controller.rb`, `test/auth_test.rb`
- Modify: `lib/chrono_forge/dashboard.rb` (expose `.configure`/`.config`), `app/controllers/chrono_forge/dashboard/workflows_controller.rb` (inherit `BaseController`)

**Acceptance Criteria:**
- [ ] Mounting + requesting with no auth configured raises `AuthenticationNotConfigured`
- [ ] `http_basic` accepts correct creds, 401s wrong creds
- [ ] `authenticate` hook runs and can deny
- [ ] `authentication = :none` permits

**Verify:** `cd chrono_forge-dashboard && bundle exec ruby -Itest test/auth_test.rb`

**Steps:**

- [ ] **Step 1: Write the failing tests** — `chrono_forge-dashboard/test/auth_test.rb`:

```ruby
require "test_helper"

class AuthTest < ActionDispatch::IntegrationTest
  def teardown
    ChronoForge::Dashboard.reset_configuration!
  end

  test "raises when nothing is configured" do
    assert_raises(ChronoForge::Dashboard::AuthenticationNotConfigured) { get "/chrono_forge" }
  end

  test "http basic accepts correct credentials" do
    ChronoForge::Dashboard.configure { |c| c.http_basic = { username: "a", password: "b" } }
    get "/chrono_forge", headers: { "HTTP_AUTHORIZATION" => ActionController::HttpAuthentication::Basic.encode_credentials("a", "b") }
    assert_response :success
  end

  test "http basic rejects wrong credentials" do
    ChronoForge::Dashboard.configure { |c| c.http_basic = { username: "a", password: "b" } }
    get "/chrono_forge", headers: { "HTTP_AUTHORIZATION" => ActionController::HttpAuthentication::Basic.encode_credentials("a", "x") }
    assert_response :unauthorized
  end

  test "hook can deny" do
    ChronoForge::Dashboard.configure { |c| c.authenticate { |ctrl| ctrl.head(:forbidden) } }
    get "/chrono_forge"
    assert_response :forbidden
  end

  test "authentication :none permits" do
    ChronoForge::Dashboard.configure { |c| c.authentication = :none }
    get "/chrono_forge"
    assert_response :success
  end
end
```

- [ ] **Step 2: Run — confirm failures** (`AuthenticationNotConfigured` / `reset_configuration!` undefined).

- [ ] **Step 3: Configuration object** — `lib/chrono_forge/dashboard/configuration.rb`:

```ruby
module ChronoForge
  module Dashboard
    class AuthenticationNotConfigured < StandardError
      MESSAGE = <<~MSG.freeze
        ChronoForge::Dashboard has no authentication configured. Do one of:
          - ChronoForge::Dashboard.configure { |c| c.http_basic = { username:, password: } }
          - ChronoForge::Dashboard.configure { |c| c.authenticate { |controller| ... } }
          - ChronoForge::Dashboard.configure { |c| c.authentication = :none }  # then guard the mount with your own routing constraint
      MSG
      def initialize(msg = MESSAGE) = super
    end

    class Configuration
      attr_accessor :http_basic, :authentication
      attr_reader :auth_hook
      attr_accessor :polling_interval, :page_size, :long_wait_threshold

      def initialize
        @http_basic = nil
        @authentication = nil      # nil = unconfigured (fail closed); :none = explicitly open
        @auth_hook = nil
        @polling_interval = 5
        @page_size = 50
        @long_wait_threshold = 3600 # seconds
      end

      def authenticate(&block) = @auth_hook = block
    end
  end
end
```

- [ ] **Step 4: Entry exposes config** — append to `lib/chrono_forge/dashboard.rb`:

```ruby
require "chrono_forge/dashboard/configuration"

module ChronoForge
  module Dashboard
    class << self
      def config = (@config ||= Configuration.new)
      def configure = yield(config)
      def reset_configuration! = @config = Configuration.new
    end
  end
end
```

- [ ] **Step 5: BaseController** — `app/controllers/chrono_forge/dashboard/base_controller.rb`:

```ruby
module ChronoForge
  module Dashboard
    class BaseController < ActionController::Base
      protect_from_forgery with: :exception
      before_action :authenticate!

      private

      def authenticate!
        config = ChronoForge::Dashboard.config
        if config.auth_hook
          instance_exec(self, &config.auth_hook)
        elsif config.http_basic
          creds = config.http_basic
          authenticate_or_request_with_http_basic("ChronoForge") do |u, p|
            ActiveSupport::SecurityUtils.secure_compare(u, creds[:username]) &
              ActiveSupport::SecurityUtils.secure_compare(p, creds[:password])
          end
        elsif config.authentication == :none
          true
        else
          raise AuthenticationNotConfigured
        end
      end
    end
  end
end
```

Update `WorkflowsController` to inherit it (keep the stub `index` for now):

```ruby
module ChronoForge
  module Dashboard
    class WorkflowsController < BaseController
      def index
        render plain: "ChronoForge Dashboard"
      end
    end
  end
end
```

- [ ] **Step 6: Run — confirm green**, then full suite (`bundle exec rake test`).

- [ ] **Step 7: Commit**

```bash
git add chrono_forge-dashboard
git commit -m "feat(dashboard): fail-closed pluggable authentication"
```

```json:metadata
{"files": ["chrono_forge-dashboard/lib/chrono_forge/dashboard/configuration.rb", "chrono_forge-dashboard/lib/chrono_forge/dashboard.rb", "chrono_forge-dashboard/app/controllers/chrono_forge/dashboard/base_controller.rb", "chrono_forge-dashboard/test/auth_test.rb"], "verifyCommand": "cd chrono_forge-dashboard && bundle exec ruby -Itest test/auth_test.rb", "acceptanceCriteria": ["raises unconfigured", "http_basic accept/reject", "hook denies", ":none permits"], "requiresUserVerification": false}
```

---

### Task 3: Step-name parser

**Goal:** Pure parser decoding core step names into a struct.

**Files:** Create `lib/chrono_forge/dashboard/step_name_parser.rb`, `test/step_name_parser_test.rb`

**Acceptance Criteria:**
- [ ] Parses `durably_execute$x` → kind `:execute`, name `"x"`
- [ ] Parses `wait_until$cond` → kind `:wait`, name `"cond"`
- [ ] Parses `durably_repeat$x` → kind `:repeat_coordination`, name `"x"`, no timestamp
- [ ] Parses `durably_repeat$x$1717000000` → kind `:repeat_run`, name `"x"`, timestamp Integer
- [ ] Unrecognized names → kind `:unknown`, raw preserved, never raises

**Verify:** `cd chrono_forge-dashboard && bundle exec ruby -Itest test/step_name_parser_test.rb`

**Steps:**

- [ ] **Step 1: Failing test** — `test/step_name_parser_test.rb`:

```ruby
require "test_helper"

class StepNameParserTest < ActiveSupport::TestCase
  P = ChronoForge::Dashboard::StepNameParser

  test "durably_execute" do
    r = P.parse("durably_execute$charge_card")
    assert_equal :execute, r.kind
    assert_equal "charge_card", r.name
    assert_nil r.timestamp
  end

  test "wait_until" do
    assert_equal :wait, P.parse("wait_until$paid?").kind
    assert_equal "paid?", P.parse("wait_until$paid?").name
  end

  test "durably_repeat coordination" do
    r = P.parse("durably_repeat$remind")
    assert_equal :repeat_coordination, r.kind
    assert_equal "remind", r.name
    assert_nil r.timestamp
  end

  test "durably_repeat run" do
    r = P.parse("durably_repeat$remind$1717000000")
    assert_equal :repeat_run, r.kind
    assert_equal "remind", r.name
    assert_equal 1717000000, r.timestamp
  end

  test "unknown is preserved, never raises" do
    r = P.parse("legacy_thing")
    assert_equal :unknown, r.kind
    assert_equal "legacy_thing", r.raw
  end
end
```

- [ ] **Step 2: Run — confirm fail.**

- [ ] **Step 3: Implement** — `lib/chrono_forge/dashboard/step_name_parser.rb`:

```ruby
module ChronoForge
  module Dashboard
    module StepNameParser
      Parsed = Struct.new(:kind, :name, :timestamp, :raw, keyword_init: true)
      DELIM = "$"

      def self.parse(step_name)
        prefix, name, ts = step_name.to_s.split(DELIM, 3)
        case prefix
        when "durably_execute" then Parsed.new(kind: :execute, name: name, raw: step_name)
        when "wait_until"      then Parsed.new(kind: :wait, name: name, raw: step_name)
        when "durably_repeat"
          if ts
            Parsed.new(kind: :repeat_run, name: name, timestamp: Integer(ts, exception: false), raw: step_name)
          else
            Parsed.new(kind: :repeat_coordination, name: name, raw: step_name)
          end
        else
          Parsed.new(kind: :unknown, name: step_name, raw: step_name)
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run — green.**

- [ ] **Step 5: Commit**

```bash
git add chrono_forge-dashboard
git commit -m "feat(dashboard): step-name parser"
```

```json:metadata
{"files": ["chrono_forge-dashboard/lib/chrono_forge/dashboard/step_name_parser.rb", "chrono_forge-dashboard/test/step_name_parser_test.rb"], "verifyCommand": "cd chrono_forge-dashboard && bundle exec ruby -Itest test/step_name_parser_test.rb", "acceptanceCriteria": ["execute/wait/repeat-coord/repeat-run parsed", "unknown preserved, never raises"], "requiresUserVerification": false}
```

---

### Task 4: Query objects (WorkflowsQuery, StatsQuery)

**Goal:** Filter/paginate the workflow list and compute state counts in one grouped query.

**Files:** Create `app/queries/chrono_forge/dashboard/workflows_query.rb`, `app/queries/chrono_forge/dashboard/stats_query.rb`, `test/queries_test.rb`

**Acceptance Criteria:**
- [ ] `WorkflowsQuery` filters by `state`, `job_class`, `key` (substring), and `created` date range; paginates by `page`/`per`
- [ ] Blank filters are ignored (return all)
- [ ] `StatsQuery#counts` returns a hash of state-name → count for every state (zeros included)

**Verify:** `cd chrono_forge-dashboard && bundle exec ruby -Itest test/queries_test.rb`

**Steps:**

- [ ] **Step 1: Failing test** — `test/queries_test.rb`:

```ruby
require "test_helper"

class QueriesTest < ActiveSupport::TestCase
  include DashboardTestHelpers

  setup do
    create_workflow(key: "a", state: :failed, job_class: "OrderWorkflow")
    create_workflow(key: "b", state: :completed, job_class: "OrderWorkflow")
    create_workflow(key: "c", state: :failed, job_class: "PayoutWorkflow")
  end

  test "filters by state" do
    q = ChronoForge::Dashboard::WorkflowsQuery.new(state: "failed")
    assert_equal %w[a c].sort, q.results.map(&:key).sort
  end

  test "filters by job_class and key substring" do
    assert_equal ["a"], ChronoForge::Dashboard::WorkflowsQuery.new(job_class: "OrderWorkflow", key: "a").results.map(&:key)
  end

  test "blank filters return all" do
    assert_equal 3, ChronoForge::Dashboard::WorkflowsQuery.new(state: "", job_class: nil).results.count
  end

  test "paginates" do
    q = ChronoForge::Dashboard::WorkflowsQuery.new(page: 1, per: 2)
    assert_equal 2, q.results.to_a.size
    assert_equal 3, q.total_count
  end

  test "stats counts every state" do
    counts = ChronoForge::Dashboard::StatsQuery.new.counts
    assert_equal 2, counts["failed"]
    assert_equal 1, counts["completed"]
    assert_equal 0, counts["running"]
  end
end
```

- [ ] **Step 2: Run — confirm fail.**

- [ ] **Step 3: Implement** — `app/queries/chrono_forge/dashboard/workflows_query.rb`:

```ruby
module ChronoForge
  module Dashboard
    class WorkflowsQuery
      DEFAULT_PER = 50

      def initialize(state: nil, job_class: nil, key: nil, created_from: nil, created_to: nil, page: 1, per: DEFAULT_PER)
        @state = state.presence
        @job_class = job_class.presence
        @key = key.presence
        @created_from = created_from.presence
        @created_to = created_to.presence
        @page = [page.to_i, 1].max
        @per = [per.to_i, 1].max
      end

      def results = scope.order(created_at: :desc).limit(@per).offset((@page - 1) * @per)

      def total_count = scope.count

      def page = @page
      def per = @per

      private

      def scope
        s = ChronoForge::Workflow.all
        s = s.where(state: ChronoForge::Workflow.states[@state]) if @state && ChronoForge::Workflow.states.key?(@state)
        s = s.where(job_class: @job_class) if @job_class
        s = s.where("key LIKE ?", "%#{@key}%") if @key
        s = s.where("created_at >= ?", @created_from) if @created_from
        s = s.where("created_at <= ?", @created_to) if @created_to
        s
      end
    end
  end
end
```

`app/queries/chrono_forge/dashboard/stats_query.rb`:

```ruby
module ChronoForge
  module Dashboard
    class StatsQuery
      # Hash of state-name => count, zero-filled for every state.
      def counts
        grouped = ChronoForge::Workflow.group(:state).count # {0=>n, ...} keyed by enum int
        by_name = grouped.transform_keys { |i| ChronoForge::Workflow.states.key(i) }
        ChronoForge::Workflow.states.keys.index_with { |name| by_name[name].to_i }
      end
    end
  end
end
```

- [ ] **Step 4: Run — green.**

- [ ] **Step 5: Commit**

```bash
git add chrono_forge-dashboard
git commit -m "feat(dashboard): workflows + stats query objects"
```

```json:metadata
{"files": ["chrono_forge-dashboard/app/queries/chrono_forge/dashboard/workflows_query.rb", "chrono_forge-dashboard/app/queries/chrono_forge/dashboard/stats_query.rb", "chrono_forge-dashboard/test/queries_test.rb"], "verifyCommand": "cd chrono_forge-dashboard && bundle exec ruby -Itest test/queries_test.rb", "acceptanceCriteria": ["state/job_class/key/date filters", "blank ignored", "pagination + total_count", "stats zero-filled"], "requiresUserVerification": false}
```

---

### Task 5: Workflows#index — list, filters, stats, pagination

**Goal:** The list page with state badges, filters, a stats header, and pagination, plus its controller tests.

**Files:**
- Modify: `app/controllers/chrono_forge/dashboard/workflows_controller.rb`
- Create: layout `app/views/layouts/chrono_forge/dashboard/application.html.erb`; `app/views/chrono_forge/dashboard/workflows/index.html.erb` + `_stats.html.erb`, `_filters.html.erb`, `_workflow_row.html.erb`; helper `app/helpers/chrono_forge/dashboard/dashboard_helper.rb`; `test/workflows_index_test.rb`

**Acceptance Criteria:**
- [ ] `index` lists workflows newest-first with a state badge, key, class, timestamps
- [ ] Filtering by `state`/`job_class`/`key` narrows the list
- [ ] Stats header shows per-state counts
- [ ] Pagination links present when `total_count > per`

**Verify:** `cd chrono_forge-dashboard && bundle exec ruby -Itest test/workflows_index_test.rb`

**Steps:**

- [ ] **Step 1: Failing test** — `test/workflows_index_test.rb`:

```ruby
require "test_helper"

class WorkflowsIndexTest < ActionDispatch::IntegrationTest
  include DashboardTestHelpers

  setup do
    ChronoForge::Dashboard.configure { |c| c.authentication = :none }
    create_workflow(key: "ord-1", state: :failed, job_class: "OrderWorkflow")
    create_workflow(key: "pay-1", state: :completed, job_class: "PayoutWorkflow")
  end
  teardown { ChronoForge::Dashboard.reset_configuration! }

  test "lists workflows with badges" do
    get "/chrono_forge/workflows"
    assert_response :success
    assert_match "ord-1", response.body
    assert_match "pay-1", response.body
    assert_match "cf-badge--failed", response.body
  end

  test "filters by state" do
    get "/chrono_forge/workflows", params: { state: "failed" }
    assert_match "ord-1", response.body
    refute_match "pay-1", response.body
  end

  test "stats header shows counts" do
    get "/chrono_forge/workflows"
    assert_match "cf-stat", response.body
  end
end
```

- [ ] **Step 2: Run — confirm fail.**

- [ ] **Step 3: Controller**:

```ruby
module ChronoForge
  module Dashboard
    class WorkflowsController < BaseController
      def index
        @query = WorkflowsQuery.new(**list_params)
        @workflows = @query.results
        @stats = StatsQuery.new.counts
      end

      private

      def list_params
        params.permit(:state, :job_class, :key, :created_from, :created_to, :page)
          .to_h.symbolize_keys.merge(per: ChronoForge::Dashboard.config.page_size)
      end
    end
  end
end
```

- [ ] **Step 4: Helper** — `app/helpers/chrono_forge/dashboard/dashboard_helper.rb`:

```ruby
module ChronoForge
  module Dashboard
    module DashboardHelper
      def cf_badge(state)
        tag.span(state, class: "cf-badge cf-badge--#{state}")
      end

      def cf_duration(from, to)
        return "—" unless from && to
        secs = (to - from).to_i
        "#{secs}s"
      end
    end
  end
end
```

- [ ] **Step 5: Layout** — `app/views/layouts/chrono_forge/dashboard/application.html.erb`:

```erb
<!DOCTYPE html>
<html>
<head>
  <title>ChronoForge</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <%= csrf_meta_tags %>
  <link rel="stylesheet" href="<%= main_app.respond_to?(:cf_dashboard_css_path) ? cf_dashboard_css_path : "#{request.script_name}/assets/dashboard.css" %>">
</head>
<body data-poll-interval="<%= ChronoForge::Dashboard.config.polling_interval %>">
  <header class="cf-header"><a href="<%= root_path %>">ChronoForge</a></header>
  <main class="cf-main"><%= yield %></main>
  <script src="<%= request.script_name %>/assets/dashboard.js"></script>
</body>
</html>
```

(The asset routes are added in Task 10; until then the `<link>`/`<script>` 404 harmlessly in tests, which assert on body text, not assets.)

- [ ] **Step 6: Views** — `index.html.erb`:

```erb
<%= render "stats", stats: @stats %>
<%= render "filters", query: @query %>
<table class="cf-table">
  <thead><tr><th>State</th><th>Key</th><th>Class</th><th>Started</th><th>Updated</th></tr></thead>
  <tbody>
    <%= render partial: "workflow_row", collection: @workflows, as: :workflow %>
  </tbody>
</table>
<nav class="cf-pager">
  <% if @query.page > 1 %><%= link_to "‹ Prev", request.params.merge(page: @query.page - 1) %><% end %>
  <% if @query.total_count > @query.page * @query.per %><%= link_to "Next ›", request.params.merge(page: @query.page + 1) %><% end %>
</nav>
```

`_stats.html.erb`:

```erb
<div class="cf-stats">
  <% stats.each do |state, count| %>
    <span class="cf-stat cf-stat--<%= state %>"><%= cf_badge(state) %> <%= count %></span>
  <% end %>
</div>
```

`_filters.html.erb`:

```erb
<%= form_with url: workflows_path, method: :get, class: "cf-filters" do |f| %>
  <%= f.select :state, ["", *ChronoForge::Workflow.states.keys], { selected: params[:state] } %>
  <%= f.text_field :job_class, value: params[:job_class], placeholder: "Job class" %>
  <%= f.text_field :key, value: params[:key], placeholder: "Key" %>
  <%= f.submit "Filter" %>
<% end %>
```

`_workflow_row.html.erb`:

```erb
<tr>
  <td><%= cf_badge(workflow.state) %></td>
  <td><%= link_to workflow.key, workflow_path(workflow) %></td>
  <td><%= workflow.job_class %></td>
  <td><%= workflow.started_at&.iso8601 %></td>
  <td><%= workflow.updated_at&.iso8601 %></td>
</tr>
```

- [ ] **Step 7: Run — green**, then full suite.

- [ ] **Step 8: Commit**

```bash
git add chrono_forge-dashboard
git commit -m "feat(dashboard): workflow list with filters, stats, pagination"
```

```json:metadata
{"files": ["chrono_forge-dashboard/app/controllers/chrono_forge/dashboard/workflows_controller.rb", "chrono_forge-dashboard/app/views/chrono_forge/dashboard/workflows/index.html.erb", "chrono_forge-dashboard/app/views/layouts/chrono_forge/dashboard/application.html.erb", "chrono_forge-dashboard/app/helpers/chrono_forge/dashboard/dashboard_helper.rb", "chrono_forge-dashboard/test/workflows_index_test.rb"], "verifyCommand": "cd chrono_forge-dashboard && bundle exec ruby -Itest test/workflows_index_test.rb", "acceptanceCriteria": ["list with badges", "state filter narrows", "stats header", "pager"], "requiresUserVerification": false}
```

---

### Task 6: Timeline + Context presenters

**Goal:** Build the replay timeline from `execution_logs` (repetitions rolled under their coordination log) and render context as a tree model.

**Files:** Create `app/presenters/chrono_forge/dashboard/timeline_presenter.rb`, `app/presenters/chrono_forge/dashboard/context_presenter.rb`, `test/presenters_test.rb`

**Acceptance Criteria:**
- [ ] Timeline orders entries by `started_at`; each has `kind`, `status`, `attempts`, `started_at`, `completed_at`, `error`
- [ ] `durably_repeat` runs are grouped as children of their coordination entry
- [ ] Current position = last failed/running entry, else active wait, else nil
- [ ] `ContextPresenter#nodes` yields `{key, value, type}` and a total byte size

**Verify:** `cd chrono_forge-dashboard && bundle exec ruby -Itest test/presenters_test.rb`

**Steps:**

- [ ] **Step 1: Failing test** — `test/presenters_test.rb`:

```ruby
require "test_helper"

class PresentersTest < ActiveSupport::TestCase
  include DashboardTestHelpers

  def log(wf, step_name, state:, attempts: 1, started_at: Time.current, completed_at: nil, **attrs)
    ChronoForge::ExecutionLog.create!(workflow: wf, step_name: step_name,
      state: ChronoForge::ExecutionLog.states[state], attempts: attempts,
      started_at: started_at, completed_at: completed_at, **attrs)
  end

  test "timeline orders and rolls up repetitions" do
    wf = create_workflow(key: "t1")
    log(wf, "durably_execute$validate", state: :completed, started_at: 3.minutes.ago)
    coord = log(wf, "durably_repeat$remind", state: :pending, started_at: 2.minutes.ago)
    log(wf, "durably_repeat$remind$1717000000", state: :completed, started_at: 1.minute.ago)

    tl = ChronoForge::Dashboard::TimelinePresenter.new(wf)
    kinds = tl.entries.map(&:kind)
    assert_equal :execute, kinds.first
    repeat = tl.entries.find { |e| e.kind == :repeat_coordination }
    assert_equal 1, repeat.runs.size
  end

  test "current position is the failed step" do
    wf = create_workflow(key: "t2", state: :failed)
    log(wf, "durably_execute$a", state: :completed, started_at: 2.minutes.ago)
    failed = log(wf, "durably_execute$b", state: :failed, started_at: 1.minute.ago, error_class: "Boom")
    tl = ChronoForge::Dashboard::TimelinePresenter.new(wf)
    assert_equal failed.id, tl.current_position.id
  end

  test "context presenter exposes typed nodes and size" do
    wf = create_workflow(key: "t3", context: { "amount" => 5, "intl" => true })
    cp = ChronoForge::Dashboard::ContextPresenter.new(wf)
    types = cp.nodes.map { |n| [n[:key], n[:type]] }.to_h
    assert_equal "Integer", types["amount"]
    assert_equal "TrueClass", types["intl"]
    assert_operator cp.byte_size, :>, 0
  end
end
```

- [ ] **Step 2: Run — confirm fail.**

- [ ] **Step 3: Implement** — `app/presenters/chrono_forge/dashboard/timeline_presenter.rb`:

```ruby
module ChronoForge
  module Dashboard
    class TimelinePresenter
      Entry = Struct.new(:id, :kind, :name, :status, :attempts, :started_at, :completed_at, :error, :runs, keyword_init: true)

      def initialize(workflow) = @workflow = workflow

      # Ordered timeline; repeat_run logs nested under their coordination entry.
      def entries
        @entries ||= build
      end

      # The log row representing where the workflow currently sits.
      def current_position
        logs = ordered_logs
        logs.reverse.find { |l| l.failed? } ||
          logs.reverse.find { |l| l.pending? && StepNameParser.parse(l.step_name).kind == :wait } ||
          logs.last
      end

      private

      def ordered_logs
        @ordered_logs ||= @workflow.execution_logs.order(Arel.sql("started_at, id")).to_a
      end

      def build
        coord_by_name = {}
        top = []
        ordered_logs.each do |l|
          p = StepNameParser.parse(l.step_name)
          entry = Entry.new(id: l.id, kind: p.kind, name: p.name, status: l.state,
            attempts: l.attempts, started_at: l.started_at, completed_at: l.completed_at,
            error: l.error_class, runs: [])
          if p.kind == :repeat_coordination
            coord_by_name[p.name] = entry
            top << entry
          elsif p.kind == :repeat_run && (parent = coord_by_name[p.name])
            parent.runs << entry
          else
            top << entry
          end
        end
        top
      end
    end
  end
end
```

`app/presenters/chrono_forge/dashboard/context_presenter.rb`:

```ruby
module ChronoForge
  module Dashboard
    class ContextPresenter
      MAX_VALUE_BYTES = 16.kilobytes

      def initialize(workflow) = @workflow = workflow

      def nodes
        context.map { |k, v| { key: k, value: v, type: v.class.name, bytes: v.to_json.bytesize } }
      end

      def byte_size = context.to_json.bytesize

      private

      def context = @workflow.context || {}
    end
  end
end
```

- [ ] **Step 4: Run — green.**

- [ ] **Step 5: Commit**

```bash
git add chrono_forge-dashboard
git commit -m "feat(dashboard): timeline and context presenters"
```

```json:metadata
{"files": ["chrono_forge-dashboard/app/presenters/chrono_forge/dashboard/timeline_presenter.rb", "chrono_forge-dashboard/app/presenters/chrono_forge/dashboard/context_presenter.rb", "chrono_forge-dashboard/test/presenters_test.rb"], "verifyCommand": "cd chrono_forge-dashboard && bundle exec ruby -Itest test/presenters_test.rb", "acceptanceCriteria": ["timeline order + repetition rollup", "current position", "typed context nodes + size"], "requiresUserVerification": false}
```

---

### Task 7: Workflows#show — timeline, context tree, errors, wait callout

**Goal:** The detail page wiring the presenters and error logs into the view.

**Files:**
- Modify: `app/controllers/chrono_forge/dashboard/workflows_controller.rb` (`show`)
- Create: `show.html.erb` + `_timeline.html.erb`, `_context_tree.html.erb`, `_errors.html.erb`, `_wait_callout.html.erb`; `test/workflows_show_test.rb`

**Acceptance Criteria:**
- [ ] `show` renders the timeline (one node per step, repetitions nested), context tree, and error log
- [ ] An idle workflow waiting on a `wait_until` shows the wait callout with age + timeout
- [ ] Missing/unknown step names render without raising

**Verify:** `cd chrono_forge-dashboard && bundle exec ruby -Itest test/workflows_show_test.rb`

**Steps:**

- [ ] **Step 1: Failing test** — `test/workflows_show_test.rb`:

```ruby
require "test_helper"

class WorkflowsShowTest < ActionDispatch::IntegrationTest
  include DashboardTestHelpers
  setup { ChronoForge::Dashboard.configure { |c| c.authentication = :none } }
  teardown { ChronoForge::Dashboard.reset_configuration! }

  test "renders timeline, context, errors" do
    wf = create_workflow(key: "show-1", state: :failed, context: { "amount" => 10 })
    ChronoForge::ExecutionLog.create!(workflow: wf, step_name: "durably_execute$charge",
      state: ChronoForge::ExecutionLog.states[:failed], attempts: 3, started_at: 1.minute.ago, error_class: "Boom")
    ChronoForge::ErrorLog.create!(workflow: wf, step_name: "durably_execute$charge", attempt: 3,
      error_class: "Boom", error_message: "kaboom")

    get "/chrono_forge/workflows/#{wf.id}"
    assert_response :success
    assert_match "charge", response.body
    assert_match "amount", response.body
    assert_match "kaboom", response.body
  end

  test "wait callout for idle wait_until" do
    wf = create_workflow(key: "show-2", state: :idle)
    ChronoForge::ExecutionLog.create!(workflow: wf, step_name: "wait_until$paid?",
      state: ChronoForge::ExecutionLog.states[:pending], attempts: 1,
      started_at: 2.hours.ago, last_executed_at: 2.hours.ago,
      metadata: { "timeout_at" => 1.hour.from_now })
    get "/chrono_forge/workflows/#{wf.id}"
    assert_match "cf-wait-callout", response.body
  end
end
```

- [ ] **Step 2: Run — confirm fail.**

- [ ] **Step 3: Controller `show`**:

```ruby
      def show
        @workflow = ChronoForge::Workflow.find(params[:id])
        @timeline = TimelinePresenter.new(@workflow)
        @context = ContextPresenter.new(@workflow)
        @errors = @workflow.error_logs.order(created_at: :desc)
        @wait = WaitStatePresenter.new(@workflow).active # nil unless idle-waiting (Task 8)
      end
```

(Note: `WaitStatePresenter` arrives in Task 8; Task 7 depends on Task 8 for the wait callout. If implementing 7 before 8, stub `@wait = nil` and add the callout when 8 lands. Sequence 8 before 7 if possible.)

- [ ] **Step 4: Views** — `show.html.erb`:

```erb
<h1 class="cf-title"><%= cf_badge(@workflow.state) %> <%= @workflow.key %></h1>
<p class="cf-meta"><%= @workflow.job_class %> · locked_by=<%= @workflow.locked_by || "—" %></p>
<%= render "wait_callout", wait: @wait if @wait %>
<section><h2>Timeline</h2><%= render "timeline", timeline: @timeline %></section>
<section><h2>Context</h2><%= render "context_tree", context: @context %></section>
<section><h2>Errors</h2><%= render "errors", errors: @errors %></section>
```

`_timeline.html.erb`:

```erb
<ol class="cf-timeline">
  <% timeline.entries.each do |e| %>
    <li class="cf-step cf-step--<%= e.status %> <%= "cf-step--current" if timeline.current_position&.id == e.id %>">
      <span class="cf-step__kind"><%= e.kind %></span>
      <span class="cf-step__name"><%= e.name %></span>
      <span class="cf-step__status"><%= e.status %></span>
      <span class="cf-step__attempts">×<%= e.attempts %></span>
      <% if e.error %><span class="cf-step__error"><%= e.error %></span><% end %>
      <% if e.runs.any? %>
        <ol class="cf-timeline cf-timeline--runs">
          <% e.runs.each do |r| %>
            <li class="cf-step cf-step--<%= r.status %>"><%= Time.zone.at(0) %><%= r.status %> ×<%= r.attempts %></li>
          <% end %>
        </ol>
      <% end %>
    </li>
  <% end %>
</ol>
```

`_context_tree.html.erb`:

```erb
<div class="cf-context" data-collapsible>
  <p class="cf-context__size"><%= number_to_human_size(context.byte_size) %></p>
  <ul>
    <% context.nodes.each do |n| %>
      <li><code class="cf-context__key"><%= n[:key] %></code>
        <span class="cf-context__type"><%= n[:type] %></span>
        <span class="cf-context__val"><%= n[:value].inspect.truncate(200) %></span>
      </li>
    <% end %>
  </ul>
</div>
```

`_errors.html.erb`:

```erb
<ul class="cf-errors">
  <% errors.each do |err| %>
    <li>
      <strong><%= err.error_class %></strong> (attempt <%= err.attempt %>) — <%= err.error_message %>
      <% if err.backtrace.present? %>
        <details><summary>backtrace</summary><pre><%= err.backtrace %></pre></details>
      <% end %>
    </li>
  <% end %>
</ul>
```

`_wait_callout.html.erb`:

```erb
<div class="cf-wait-callout">
  Waiting on <code><%= wait.condition %></code> for <%= distance_of_time_in_words(wait.waiting_since, Time.current) %>
  (timeout <%= wait.timeout_at&.iso8601 || "—" %>)
</div>
```

- [ ] **Step 5: Run — green**, then full suite.

- [ ] **Step 6: Commit**

```bash
git add chrono_forge-dashboard
git commit -m "feat(dashboard): workflow detail with timeline, context tree, errors"
```

```json:metadata
{"files": ["chrono_forge-dashboard/app/controllers/chrono_forge/dashboard/workflows_controller.rb", "chrono_forge-dashboard/app/views/chrono_forge/dashboard/workflows/show.html.erb", "chrono_forge-dashboard/test/workflows_show_test.rb"], "verifyCommand": "cd chrono_forge-dashboard && bundle exec ruby -Itest test/workflows_show_test.rb", "acceptanceCriteria": ["timeline+context+errors render", "wait callout for idle wait", "unknown steps don't raise"], "requiresUserVerification": false}
```

---

### Task 8: Periodic health + wait-state presenters and wait-states index

**Goal:** `durably_repeat` health, wait-state age model, and the wait-states list page.

**Files:** Create `app/presenters/chrono_forge/dashboard/periodic_health_presenter.rb`, `app/presenters/chrono_forge/dashboard/wait_state_presenter.rb`, `app/controllers/chrono_forge/dashboard/wait_states_controller.rb`, `app/views/chrono_forge/dashboard/wait_states/index.html.erb`, `test/periodic_and_wait_test.rb`

**Acceptance Criteria:**
- [ ] `PeriodicHealthPresenter` reports last run, next scheduled, timed-out count, and per-run latencies for each `durably_repeat` coordination log
- [ ] `WaitStatePresenter#active` returns `{condition, waiting_since, timeout_at}` for an idle wait, else nil
- [ ] `WaitStatesController#index` lists idle-waiting workflows sorted by wait age, flagging those past `long_wait_threshold`

**Verify:** `cd chrono_forge-dashboard && bundle exec ruby -Itest test/periodic_and_wait_test.rb`

**Steps:**

- [ ] **Step 1: Failing test** — `test/periodic_and_wait_test.rb`:

```ruby
require "test_helper"

class PeriodicAndWaitTest < ActionDispatch::IntegrationTest
  include DashboardTestHelpers
  setup { ChronoForge::Dashboard.configure { |c| c.authentication = :none } }
  teardown { ChronoForge::Dashboard.reset_configuration! }

  test "wait presenter detects active idle wait" do
    wf = create_workflow(key: "w1", state: :idle)
    ChronoForge::ExecutionLog.create!(workflow: wf, step_name: "wait_until$ready?",
      state: ChronoForge::ExecutionLog.states[:pending], attempts: 1,
      started_at: 90.minutes.ago, last_executed_at: 90.minutes.ago,
      metadata: { "timeout_at" => 1.hour.from_now })
    active = ChronoForge::Dashboard::WaitStatePresenter.new(wf).active
    assert_equal "ready?", active.condition
  end

  test "wait-states index flags long waiters" do
    wf = create_workflow(key: "w2", state: :idle)
    ChronoForge::ExecutionLog.create!(workflow: wf, step_name: "wait_until$ready?",
      state: ChronoForge::ExecutionLog.states[:pending], attempts: 1,
      started_at: 5.hours.ago, last_executed_at: 5.hours.ago, metadata: {})
    get "/chrono_forge/wait_states"
    assert_response :success
    assert_match "w2", response.body
    assert_match "cf-wait--long", response.body
  end

  test "periodic health reports timeouts and latencies" do
    wf = create_workflow(key: "p1")
    ChronoForge::ExecutionLog.create!(workflow: wf, step_name: "durably_repeat$sync",
      state: ChronoForge::ExecutionLog.states[:pending], attempts: 1, started_at: 1.day.ago,
      metadata: { "last_execution_at" => 2.hours.ago.iso8601 })
    ChronoForge::ExecutionLog.create!(workflow: wf, step_name: "durably_repeat$sync$1717000000",
      state: ChronoForge::ExecutionLog.states[:failed], attempts: 1, error_class: "TimeoutError",
      started_at: 3.hours.ago, completed_at: 3.hours.ago)
    health = ChronoForge::Dashboard::PeriodicHealthPresenter.new(wf).tasks
    assert_equal 1, health.first.timed_out_count
  end
end
```

- [ ] **Step 2: Run — confirm fail.**

- [ ] **Step 3: Implement** — `app/presenters/chrono_forge/dashboard/wait_state_presenter.rb`:

```ruby
module ChronoForge
  module Dashboard
    class WaitStatePresenter
      Active = Struct.new(:condition, :waiting_since, :timeout_at, keyword_init: true)

      def initialize(workflow) = @workflow = workflow

      # Active wait iff the workflow is idle and its latest log is a pending wait_until.
      def active
        return nil unless @workflow.idle?
        log = @workflow.execution_logs.order(Arel.sql("started_at, id")).last
        return nil unless log&.pending?
        p = StepNameParser.parse(log.step_name)
        return nil unless p.kind == :wait
        Active.new(condition: p.name,
          waiting_since: log.last_executed_at || log.started_at,
          timeout_at: log.metadata&.dig("timeout_at"))
      end
    end
  end
end
```

`app/presenters/chrono_forge/dashboard/periodic_health_presenter.rb`:

```ruby
module ChronoForge
  module Dashboard
    class PeriodicHealthPresenter
      Task = Struct.new(:name, :last_execution_at, :timed_out_count, :latencies, keyword_init: true)

      def initialize(workflow) = @workflow = workflow

      def tasks
        coords = logs.select { |l| StepNameParser.parse(l.step_name).kind == :repeat_coordination }
        coords.map do |coord|
          name = StepNameParser.parse(coord.step_name).name
          runs = logs.select do |l|
            pp = StepNameParser.parse(l.step_name)
            pp.kind == :repeat_run && pp.name == name
          end
          Task.new(
            name: name,
            last_execution_at: coord.metadata&.dig("last_execution_at"),
            timed_out_count: runs.count { |r| r.error_class == "TimeoutError" },
            latencies: runs.filter_map { |r| (r.completed_at - r.started_at).to_i if r.completed_at && r.started_at }
          )
        end
      end

      private

      def logs = @logs ||= @workflow.execution_logs.to_a
    end
  end
end
```

`app/controllers/chrono_forge/dashboard/wait_states_controller.rb`:

```ruby
module ChronoForge
  module Dashboard
    class WaitStatesController < BaseController
      def index
        idle = ChronoForge::Workflow.where(state: ChronoForge::Workflow.states[:idle])
        @waits = idle.filter_map do |wf|
          a = WaitStatePresenter.new(wf).active
          { workflow: wf, wait: a } if a
        end.sort_by { |h| h[:wait].waiting_since || Time.current }
        @threshold = ChronoForge::Dashboard.config.long_wait_threshold
      end
    end
  end
end
```

`app/views/chrono_forge/dashboard/wait_states/index.html.erb`:

```erb
<h1>Waiting workflows</h1>
<table class="cf-table">
  <thead><tr><th>Key</th><th>Condition</th><th>Waiting</th><th>Timeout</th></tr></thead>
  <tbody>
    <% @waits.each do |h| %>
      <% long = (Time.current - (h[:wait].waiting_since || Time.current)) > @threshold %>
      <tr class="<%= "cf-wait--long" if long %>">
        <td><%= link_to h[:workflow].key, workflow_path(h[:workflow]) %></td>
        <td><code><%= h[:wait].condition %></code></td>
        <td><%= distance_of_time_in_words(h[:wait].waiting_since, Time.current) %></td>
        <td><%= h[:wait].timeout_at || "—" %></td>
      </tr>
    <% end %>
  </tbody>
</table>
```

- [ ] **Step 4: Run — green.**

- [ ] **Step 5: Commit**

```bash
git add chrono_forge-dashboard
git commit -m "feat(dashboard): periodic-task health and wait-state age view"
```

```json:metadata
{"files": ["chrono_forge-dashboard/app/presenters/chrono_forge/dashboard/periodic_health_presenter.rb", "chrono_forge-dashboard/app/presenters/chrono_forge/dashboard/wait_state_presenter.rb", "chrono_forge-dashboard/app/controllers/chrono_forge/dashboard/wait_states_controller.rb", "chrono_forge-dashboard/app/views/chrono_forge/dashboard/wait_states/index.html.erb", "chrono_forge-dashboard/test/periodic_and_wait_test.rb"], "verifyCommand": "cd chrono_forge-dashboard && bundle exec ruby -Itest test/periodic_and_wait_test.rb", "acceptanceCriteria": ["periodic health timeouts+latencies", "active wait detection", "wait-states list flags long waiters"], "requiresUserVerification": false}
```

---

### Task 9: Operational actions (retry, unlock, bulk retry)

**Goal:** POST endpoints for the three recovery actions, guarded and flashing on failure.

**Files:** Modify `config/routes.rb`; create `app/controllers/chrono_forge/dashboard/actions_controller.rb`, `test/actions_test.rb`

**Acceptance Criteria:**
- [ ] `POST /workflows/:id/retry` calls `workflow.retry_later`; on a non-retryable workflow it flashes and redirects (no 500)
- [ ] `POST /workflows/:id/unlock` clears `locked_at`/`locked_by` and sets state `idle`
- [ ] `POST /workflows/bulk_retry` calls `retry_later` on every failed workflow and reports the count
- [ ] All three require CSRF + auth

**Verify:** `cd chrono_forge-dashboard && bundle exec ruby -Itest test/actions_test.rb`

**Steps:**

- [ ] **Step 1: Routes**:

```ruby
ChronoForge::Dashboard::Engine.routes.draw do
  root to: "workflows#index"
  resources :workflows, only: %i[index show] do
    member do
      post :retry, to: "actions#retry"
      post :unlock, to: "actions#unlock"
    end
    collection { post :bulk_retry, to: "actions#bulk_retry" }
  end
  resources :wait_states, only: :index
  get "assets/:file", to: "assets#show", constraints: { file: /dashboard\.(css|js)/ }
end
```

- [ ] **Step 2: Failing test** — `test/actions_test.rb`:

```ruby
require "test_helper"

class ActionsTest < ActionDispatch::IntegrationTest
  include DashboardTestHelpers
  setup { ChronoForge::Dashboard.configure { |c| c.authentication = :none } }
  teardown { ChronoForge::Dashboard.reset_configuration! }

  test "retry calls retry_later on a failed workflow" do
    wf = create_workflow(key: "r1", state: :failed)
    called = false
    ChronoForge::Workflow.any_instance.stub(:retry_later, ->(*) { called = true }) do
      post "/chrono_forge/workflows/#{wf.id}/retry"
    end
    assert_response :redirect
    assert called
  end

  test "retry on a running workflow flashes instead of 500" do
    wf = create_workflow(key: "r2", state: :running)
    post "/chrono_forge/workflows/#{wf.id}/retry"
    assert_response :redirect
    follow_redirect!
    assert_match(/cannot retry|not.*retry/i, response.body)
  end

  test "unlock clears the lock and idles" do
    wf = create_workflow(key: "u1", state: :running, locked_at: Time.current, locked_by: "job-1")
    post "/chrono_forge/workflows/#{wf.id}/unlock"
    wf.reload
    assert_nil wf.locked_at
    assert_nil wf.locked_by
    assert wf.idle?
  end

  test "bulk retry hits all failed" do
    create_workflow(key: "b1", state: :failed)
    create_workflow(key: "b2", state: :failed)
    count = 0
    ChronoForge::Workflow.any_instance.stub(:retry_later, ->(*) { count += 1 }) do
      post "/chrono_forge/workflows/bulk_retry"
    end
    assert_equal 2, count
  end
end
```

(`any_instance.stub` is provided by Minitest's `Object#stub` via `minitest/mock`; add `require "minitest/mock"` in `test_helper.rb` if needed. If `any_instance` is unavailable, assert via job enqueue using `ActiveJob::TestHelper` instead — the workflow's `retry_later` enqueues a job, so `assert_enqueued_jobs` works without stubbing.)

- [ ] **Step 3: Implement** — `app/controllers/chrono_forge/dashboard/actions_controller.rb`:

```ruby
module ChronoForge
  module Dashboard
    class ActionsController < BaseController
      rescue_from ChronoForge::Executor::WorkflowNotRetryableError do |e|
        redirect_to workflow_path(params[:id]), alert: e.message
      end

      def retry
        workflow.retry_later
        redirect_to workflow_path(workflow), notice: "Re-enqueued #{workflow.key}."
      end

      def unlock
        workflow.update!(locked_at: nil, locked_by: nil, state: :idle)
        redirect_to workflow_path(workflow), notice: "Unlocked #{workflow.key}."
      end

      def bulk_retry
        n = 0
        ChronoForge::Workflow.where(state: ChronoForge::Workflow.states[:failed]).find_each do |wf|
          wf.retry_later
          n += 1
        end
        redirect_to workflows_path, notice: "Re-enqueued #{n} failed workflow(s)."
      end

      private

      def workflow = @workflow ||= ChronoForge::Workflow.find(params[:id])
    end
  end
end
```

The layout must render flash; add to `application.html.erb` `<main>`:

```erb
<% flash.each do |type, msg| %><div class="cf-flash cf-flash--<%= type %>"><%= msg %></div><% end %>
```

- [ ] **Step 4: Run — green**, then full suite.

- [ ] **Step 5: Commit**

```bash
git add chrono_forge-dashboard
git commit -m "feat(dashboard): retry, unlock, and bulk-retry actions"
```

```json:metadata
{"files": ["chrono_forge-dashboard/config/routes.rb", "chrono_forge-dashboard/app/controllers/chrono_forge/dashboard/actions_controller.rb", "chrono_forge-dashboard/test/actions_test.rb"], "verifyCommand": "cd chrono_forge-dashboard && bundle exec ruby -Itest test/actions_test.rb", "acceptanceCriteria": ["retry calls retry_later", "non-retryable flashes not 500", "unlock clears lock+idles", "bulk retry counts"], "requiresUserVerification": false}
```

---

### Task 10: Assets controller + CSS/JS (polling, tree, sparklines, confirms)

**Goal:** Serve the engine's CSS/JS without a host pipeline; wire JS behaviors.

**Files:** Create `app/controllers/chrono_forge/dashboard/assets_controller.rb`, `app/assets/chrono_forge/dashboard/dashboard.css`, `app/assets/chrono_forge/dashboard/dashboard.js`, `test/assets_test.rb`

**Acceptance Criteria:**
- [ ] `GET /assets/dashboard.css` returns `text/css` with a long-cache header
- [ ] `GET /assets/dashboard.js` returns `application/javascript`
- [ ] An unknown asset name 404s (route constraint)

**Verify:** `cd chrono_forge-dashboard && bundle exec ruby -Itest test/assets_test.rb`

**Steps:**

- [ ] **Step 1: Failing test** — `test/assets_test.rb`:

```ruby
require "test_helper"

class AssetsTest < ActionDispatch::IntegrationTest
  setup { ChronoForge::Dashboard.configure { |c| c.authentication = :none } }
  teardown { ChronoForge::Dashboard.reset_configuration! }

  test "serves css" do
    get "/chrono_forge/assets/dashboard.css"
    assert_response :success
    assert_equal "text/css", response.media_type
    assert_match "max-age", response.headers["Cache-Control"]
  end

  test "serves js" do
    get "/chrono_forge/assets/dashboard.js"
    assert_response :success
    assert_includes ["application/javascript", "text/javascript"], response.media_type
  end
end
```

- [ ] **Step 2: Implement** — `app/controllers/chrono_forge/dashboard/assets_controller.rb`:

```ruby
module ChronoForge
  module Dashboard
    class AssetsController < BaseController
      skip_before_action :authenticate! # static assets are not sensitive

      TYPES = { "dashboard.css" => "text/css", "dashboard.js" => "application/javascript" }.freeze
      ROOT = ChronoForge::Dashboard::Engine.root.join("app/assets/chrono_forge/dashboard")

      def show
        file = params[:file]
        type = TYPES[file] or return head(:not_found)
        path = ROOT.join(file)
        return head(:not_found) unless path.file?
        response.set_header("Cache-Control", "public, max-age=31536000, immutable")
        send_file path, type: type, disposition: "inline"
      end
    end
  end
end
```

- [ ] **Step 3: CSS** — `app/assets/chrono_forge/dashboard/dashboard.css` (self-contained, `cf-` prefixed). Minimum viable, no external fonts:

```css
:root { --cf-fg:#1c1e21; --cf-muted:#6b7280; --cf-line:#e5e7eb; }
.cf-main { max-width: 1100px; margin: 0 auto; padding: 1rem; font-family: system-ui, sans-serif; color: var(--cf-fg); }
.cf-table { width:100%; border-collapse:collapse; }
.cf-table th, .cf-table td { text-align:left; padding:.4rem .6rem; border-bottom:1px solid var(--cf-line); }
.cf-badge { padding:.1rem .5rem; border-radius:1rem; font-size:.8rem; }
.cf-badge--failed,.cf-badge--stalled { background:#fee2e2; }
.cf-badge--completed { background:#dcfce7; }
.cf-badge--running { background:#dbeafe; }
.cf-badge--idle { background:#f3f4f6; }
.cf-timeline { list-style:none; padding-left:0; }
.cf-step { padding:.4rem .6rem; border-left:3px solid var(--cf-line); margin:.2rem 0; }
.cf-step--failed { border-color:#ef4444; }
.cf-step--current { background:#fff7ed; }
.cf-wait-callout,.cf-wait--long { background:#fff7ed; }
.cf-flash { padding:.5rem .8rem; margin:.5rem 0; border-radius:.3rem; }
.cf-flash--alert { background:#fee2e2; } .cf-flash--notice { background:#dcfce7; }
.cf-sparkline { height:24px; }
```

- [ ] **Step 4: JS** — `app/assets/chrono_forge/dashboard/dashboard.js` (vanilla; no inline handlers):

```javascript
(function () {
  "use strict";

  // Collapsible context tree
  document.querySelectorAll("[data-collapsible] .cf-context__key").forEach(function (el) {
    el.addEventListener("click", function () { el.closest("li").classList.toggle("cf-collapsed"); });
  });

  // Confirm destructive actions: any form with data-confirm
  document.querySelectorAll("form[data-confirm]").forEach(function (form) {
    form.addEventListener("submit", function (e) {
      if (!window.confirm(form.getAttribute("data-confirm"))) e.preventDefault();
    });
  });

  // Render inline-SVG sparklines from data-values="1,2,3"
  document.querySelectorAll("[data-sparkline]").forEach(function (el) {
    var vals = (el.getAttribute("data-values") || "").split(",").map(Number).filter(function (n) { return !isNaN(n); });
    if (!vals.length) return;
    var max = Math.max.apply(null, vals), w = 100, h = 24, step = w / Math.max(vals.length - 1, 1);
    var pts = vals.map(function (v, i) { return (i * step) + "," + (h - (max ? v / max * h : 0)); }).join(" ");
    el.innerHTML = '<svg class="cf-sparkline" viewBox="0 0 ' + w + ' ' + h + '" preserveAspectRatio="none"><polyline fill="none" stroke="currentColor" points="' + pts + '"/></svg>';
  });

  // Polling refresh of the list/stats region
  var body = document.body, interval = parseInt(body.getAttribute("data-poll-interval") || "0", 10) * 1000;
  var region = document.querySelector("[data-poll-region]");
  if (interval > 0 && region && !body.hasAttribute("data-poll-paused")) {
    setInterval(function () {
      fetch(window.location.href, { headers: { "X-Requested-With": "XMLHttpRequest" } })
        .then(function (r) { return r.text(); })
        .then(function (html) {
          var doc = new DOMParser().parseFromString(html, "text/html");
          var fresh = doc.querySelector("[data-poll-region]");
          if (fresh) region.innerHTML = fresh.innerHTML;
        }).catch(function () {});
    }, interval);
  }
})();
```

(Wrap the list table/stats in `<div data-poll-region>` in `index.html.erb`; add `data-confirm` to the unlock/bulk-retry forms; add `data-sparkline data-values="..."` where periodic latencies render.)

- [ ] **Step 5: Run — green**, then full suite + standardrb.

- [ ] **Step 6: Commit**

```bash
git add chrono_forge-dashboard
git commit -m "feat(dashboard): engine-served assets, polling, sparklines, confirms"
```

```json:metadata
{"files": ["chrono_forge-dashboard/app/controllers/chrono_forge/dashboard/assets_controller.rb", "chrono_forge-dashboard/app/assets/chrono_forge/dashboard/dashboard.css", "chrono_forge-dashboard/app/assets/chrono_forge/dashboard/dashboard.js", "chrono_forge-dashboard/test/assets_test.rb"], "verifyCommand": "cd chrono_forge-dashboard && bundle exec ruby -Itest test/assets_test.rb", "acceptanceCriteria": ["css served text/css + cache header", "js served", "unknown asset 404s"], "requiresUserVerification": false}
```

---

### Task 11: README + install docs for the dashboard gem

**Goal:** A README so users can install, mount, and configure auth.

**Files:** Create `chrono_forge-dashboard/README.md`, `chrono_forge-dashboard/MIT-LICENSE`; modify the core `README.md` (add a short "Dashboard" section linking to the gem).

**Acceptance Criteria:**
- [ ] README covers install (`gem "chrono_forge-dashboard"`), mounting, and all three auth modes incl. the fail-closed behavior
- [ ] Core README has a Dashboard section pointing to the companion gem

**Verify:** `grep -n "chrono_forge-dashboard" chrono_forge-dashboard/README.md` and `grep -n "Dashboard" README.md`

**Steps:**

- [ ] **Step 1: Write `chrono_forge-dashboard/README.md`** covering: what it is, `gem "chrono_forge-dashboard"`, `mount ChronoForge::Dashboard::Engine, at: "/chrono_forge"`, the three auth modes (http_basic / hook / `:none` + routing constraint) and that it raises if unconfigured, plus `polling_interval`/`page_size`/`long_wait_threshold` config. Include the `MIT-LICENSE` file.

- [ ] **Step 2: Core README Dashboard section** — after the Features list, a short subsection: "ChronoForge has a free, mountable dashboard — see `chrono_forge-dashboard`," with the mount snippet.

- [ ] **Step 3: Commit**

```bash
git add chrono_forge-dashboard/README.md chrono_forge-dashboard/MIT-LICENSE README.md
git commit -m "docs(dashboard): README, install/mount/auth, core README link"
```

```json:metadata
{"files": ["chrono_forge-dashboard/README.md", "README.md"], "verifyCommand": "grep -n 'Dashboard' README.md", "acceptanceCriteria": ["install+mount+three auth modes documented", "core README links the gem"], "requiresUserVerification": false}
```

---

## Self-Review

**Spec coverage:** packaging/engine/exclusion → T1; auth fail-closed → T2; step-name parsing → T3; queries/stats → T4; list/filters/stats/pagination → T5; timeline + context presenters → T6; detail view → T7; periodic health + wait-state → T8; actions (retry/unlock/bulk) → T9; assets + polling/sparklines/confirms → T10; docs → T11. All spec sections covered. (Real-time push, context editing, context-value search, UI-triggered cleanup are explicitly out of scope in the spec — no tasks, correctly.)

**Sequencing note:** Task 7's wait callout depends on `WaitStatePresenter` (Task 8). Recommended execution order: 1, 2, 3, 4, 5, 6, **8, 7**, 9, 10, 11 — or implement Task 7 with `@wait = nil` and add the callout line when 8 lands. Captured in the task dependencies.

**Placeholder scan:** none — every step has concrete code or an explicit, named artifact.

**Type consistency:** `StepNameParser.parse` → `Parsed(kind, name, timestamp, raw)` used consistently in T6/T8; `WorkflowsQuery#results/#total_count/#page/#per`, `StatsQuery#counts`, `TimelinePresenter#entries/#current_position`, `ContextPresenter#nodes/#byte_size`, `WaitStatePresenter#active`, `PeriodicHealthPresenter#tasks` — signatures match across tasks. Config keys (`http_basic`, `authenticate`, `authentication`, `polling_interval`, `page_size`, `long_wait_threshold`) consistent T2/T5/T8/T10.

**Verification requirement scan:** NO — the spec/prompt requires no human-in-the-loop verification of outcomes (internal tooling, test-covered). No verification task required.
