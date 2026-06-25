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
  spec.add_development_dependency "sqlite3", ">= 2.1"
  spec.add_development_dependency "standard"
end
