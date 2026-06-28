# frozen_string_literal: true

# Release flow (chrono_forge monorepo: core + dashboard)
# ------------------------------------------------------
# Publishing happens from a laptop. CI does NOT push to any registry — it only
# cuts the GitHub Release (notes + the built gem) when the tag lands.
#
#   1. rake release:core:prepare           # auto-computes next version (git-cliff)
#      rake release:core:prepare[0.11.0]   # ...or pass one explicitly
#   2. git diff                            # review the bump + changelog (nothing committed yet)
#   3. rake release:core:publish           # commit, build + push gem, then tag + push → CI cuts the Release
#
# Same tasks under release:dashboard:*. Release `core` BEFORE `dashboard` —
# the dashboard depends on core, so bump its `chrono_forge` floor first if needed.
#
# prepare leaves the bump + changelog UNCOMMITTED so you can review the diff
# first; publish commits them, then publishes. publish is idempotent + resumable:
# it skips a gem already live and only tags if the tag is missing, so a partial
# failure can just be re-run.

RELEASE_CLIFF_CONFIG = "cliff.toml"

# Per-gem config. tag_pattern + scope mirror what each CHANGELOG should reflect:
# core = everything except the dashboard subtree, dashboard = only that subtree.
RELEASE_GEMS = {
  "core" => {
    name: "chrono_forge",
    version_file: "lib/chrono_forge/version.rb",
    changelog: "CHANGELOG.md",
    gemspec: "chrono_forge.gemspec",
    build_dir: ".",
    tag_prefix: "v",
    tag_pattern: "^v[0-9]",
    scope: ["--exclude-path", "chrono_forge-dashboard/**"],
    extra_files: []
  },
  "dashboard" => {
    name: "chrono_forge-dashboard",
    version_file: "chrono_forge-dashboard/lib/chrono_forge/dashboard/version.rb",
    changelog: "chrono_forge-dashboard/CHANGELOG.md",
    gemspec: "chrono_forge-dashboard.gemspec",
    build_dir: "chrono_forge-dashboard",
    tag_prefix: "chrono_forge-dashboard-v",
    tag_pattern: "^chrono_forge-dashboard-v[0-9]",
    scope: ["--include-path", "chrono_forge-dashboard/**"],
    # The dashboard ships a compiled stylesheet — recompile it so the tagged
    # tree (and the gem) never ship CSS that lags the source/views.
    assets: -> {
      Dir.chdir("chrono_forge-dashboard") do
        system("bundle", "exec", "rake", "tailwind:build") || abort("tailwind:build failed")
      end
    },
    extra_files: ["chrono_forge-dashboard/app/assets/chrono_forge/dashboard/dashboard.css"]
  }
}

namespace :release do
  # --- helpers --------------------------------------------------------------

  def git_cliff?
    system("which git-cliff > /dev/null 2>&1")
  end

  def release_current_version(cfg)
    File.read(cfg[:version_file])[/VERSION = "([\d.]+)"/, 1] ||
      abort("Could not read VERSION from #{cfg[:version_file]}")
  end

  def release_cliff_cmd(cfg, *extra)
    ["git-cliff", "--config", RELEASE_CLIFF_CONFIG, "--tag-pattern", cfg[:tag_pattern], *cfg[:scope], *extra]
  end

  # Capture git-cliff stdout, discarding the stderr update-check chatter.
  def release_capture(cmd)
    IO.popen(cmd, err: File::NULL, &:read)
  end

  # Next version per conventional commits. git-cliff owns the semver math
  # (including the pre-1.0 rules under [bump] in cliff.toml). Returns it
  # without the gem's tag prefix.
  def release_next_version(cfg)
    abort "git-cliff not found. Install with: brew install git-cliff" unless git_cliff?
    bumped = release_capture(release_cliff_cmd(cfg, "--bumped-version")).strip
    abort "git-cliff could not compute a version (no conventional commits since the last #{cfg[:name]} tag?)" if bumped.empty?
    bumped.delete_prefix(cfg[:tag_prefix])
  end

  def release_gem_published?(cfg, version)
    out = `gem list --remote --exact --all #{cfg[:name]} 2>/dev/null`
    out.include?("#{version},") || out.include?("#{version})") || out.include?(" #{version} ")
  end

  # Inject ONLY this version's section above the latest entry. A full -o regen
  # would misattribute past releases because path-filtering confuses cliff's
  # historical tag boundaries; existing entries are preserved verbatim.
  def release_prepend_changelog(path, section)
    body = File.read(path)
    block = "#{section.strip}\n\n"
    updated = (body =~ /^## \[/) ? body.sub(/^## \[/, "#{block}## [") : "#{body.rstrip}\n\n#{block}"
    File.write(path, updated)
  end

  # --- per-gem tasks --------------------------------------------------------

  RELEASE_GEMS.each do |key, cfg|
    namespace key do
      desc "Show #{cfg[:name]}'s next version computed from conventional commits"
      task :version do
        puts "#{cfg[:name]} current: #{release_current_version(cfg)}"
        puts "#{cfg[:name]} next:    #{release_next_version(cfg)}"
      end

      desc "Prepare a #{cfg[:name]} release commit (bump + changelog + assets). Version optional; git-cliff computes it."
      task :prepare, [:version] do |_t, args|
        version = args[:version] || release_next_version(cfg)
        abort "Error: version must be in format X.Y.Z (got #{version.inspect})" unless version.match?(/^\d+\.\d+\.\d+$/)
        abort "Error: working tree is dirty. Commit or stash first." unless `git status --porcelain`.strip.empty?
        abort "Error: not on main." unless `git rev-parse --abbrev-ref HEAD`.strip == "main"

        system("git fetch -q origin")
        abort "Error: main is not in sync with origin/main." unless `git rev-parse HEAD`.strip == `git rev-parse origin/main`.strip

        tag = "#{cfg[:tag_prefix]}#{version}"
        abort "Error: tag #{tag} already exists." if system("git rev-parse #{tag} >/dev/null 2>&1")

        puts "Preparing #{cfg[:name]} #{version} (tag #{tag})..."

        # Bump version.
        content = File.read(cfg[:version_file])
        File.write(cfg[:version_file], content.gsub(/VERSION = "[\d.]+"/, %(VERSION = "#{version}")))
        puts "✓ #{cfg[:version_file]}"

        # Compile assets (dashboard CSS), if any.
        cfg[:assets]&.call

        # Changelog — same config CI uses for the notes, so they agree.
        section = release_capture(release_cliff_cmd(cfg, "--tag", tag, "--unreleased", "--strip", "all"))
        abort "git-cliff found no entries since the last #{cfg[:name]} tag — nothing to release." if section.strip.empty?
        release_prepend_changelog(cfg[:changelog], section)
        puts "✓ #{cfg[:changelog]}"

        # Leave everything uncommitted so the bump + changelog can be reviewed
        # before anything is committed or published. publish makes the commit.
        files = [cfg[:version_file], cfg[:changelog], *cfg[:extra_files]]

        puts "\n✓ Prepared #{cfg[:name]} #{version} — nothing committed yet."
        puts "Next:"
        puts "  git diff -- #{files.join(" ")}"
        puts "  rake release:#{key}:publish   # commit, build + push gem, then tag + push"
        puts "  (abort with: git checkout -- #{files.join(" ")})"
      end

      desc "Publish #{cfg[:name]} (build + push gem, then tag + push). Idempotent + resumable."
      task :publish do
        version = release_current_version(cfg)
        tag = "#{cfg[:tag_prefix]}#{version}"
        files = [cfg[:version_file], cfg[:changelog], *cfg[:extra_files]]

        # Commit the prepared changes (you review the diff between prepare and
        # here). Resumable: if they're already committed — e.g. a re-run after a
        # partial failure — skip straight to publishing.
        if `git status --porcelain -- #{files.join(" ")}`.strip.empty?
          unless `git log -1 --format=%s`.strip == "chore(release): #{cfg[:name]} #{version}"
            abort "Nothing prepared — run rake release:#{key}:prepare first."
          end
        else
          system("git", "add", *files) || abort("git add failed")
          system("git", "commit", "-m", "chore(release): #{cfg[:name]} #{version}") || abort("git commit failed")
          puts "✓ Committed #{cfg[:name]} #{version}"
        end

        if release_gem_published?(cfg, version)
          puts "• #{cfg[:name]} #{version} already on RubyGems — skipping"
        else
          puts "Building + pushing gem..."
          Dir.chdir(cfg[:build_dir]) do
            system("gem build #{cfg[:gemspec]}") || abort("Gem build failed")
            gem_file = "#{cfg[:name]}-#{version}.gem"
            system("gem push #{gem_file}") || abort("Gem push failed")
            File.delete(gem_file) if File.exist?(gem_file)
          end
          puts "✓ Published #{cfg[:name]} #{version} to RubyGems"
        end

        # Tag + push last, so CI cuts the Release only once the gem is live.
        branch = `git branch --show-current`.strip
        if system("git rev-parse #{tag} >/dev/null 2>&1")
          puts "• tag #{tag} already exists — skipping tag"
        else
          system("git", "tag", tag) || abort("git tag failed")
        end
        system("git", "push", "origin", branch) || abort("git push branch failed")
        system("git", "push", "origin", tag) || abort("git push tag failed")

        puts "\n✓ Released #{tag}. GitHub Actions will cut the Release from the tag."
        if key == "core"
          puts "  Next: bump the dashboard's chrono_forge floor if it should require #{version}, then release:dashboard:*"
        end
      end
    end
  end
end

# Neutralize the dangerous bare `rake release` that bundler/gem_tasks defines
# (it would tag + gem push directly). Point people at the real flow instead.
if Rake::Task.task_defined?("release")
  Rake::Task["release"].clear
  desc "Disabled — use release:core:* or release:dashboard:* (see lib/tasks/release.rake)"
  task :release do
    warn "Use `rake release:core:prepare` then `rake release:core:publish` (or :dashboard). See lib/tasks/release.rake."
  end
end
