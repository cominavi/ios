# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "securerandom"
require "time"

module CominaviOperations
  SCHEMA_VERSION = 1
  TERMINAL_STATES = %w[succeeded failed].freeze

  CommandResult = Struct.new(:stdout, :stderr, :status, keyword_init: true) do
    def success?
      status.success?
    end
  end

  MissingStatus = Struct.new(:exitstatus) do
    def success?
      false
    end
  end

  class CommandRunner
    def call(*command, chdir: nil, env: {})
      options = {}
      options[:chdir] = chdir if chdir
      stdout, stderr, status = Open3.capture3(env, *command, **options)
      CommandResult.new(stdout: stdout, stderr: stderr, status: status)
    rescue Errno::ENOENT => error
      CommandResult.new(stdout: "", stderr: error.message, status: MissingStatus.new(127))
    end
  end

  module StatusRecord
    module_function

    def write(
      path:,
      operation:,
      run_id:,
      state:,
      stage:,
      message:,
      now: Time.now.utc,
      started_at: nil,
      finished_at: nil,
      progress: nil,
      artifacts: nil,
      receipt: nil,
      error: nil
    )
      raise ArgumentError, "operation cannot be empty" if operation.to_s.strip.empty?
      raise ArgumentError, "run_id cannot be empty" if run_id.to_s.strip.empty?
      raise ArgumentError, "state cannot be empty" if state.to_s.strip.empty?
      raise ArgumentError, "stage cannot be empty" if stage.to_s.strip.empty?

      existing = read(path) || {}
      same_run = existing["runId"] == run_id
      timestamp = now.iso8601(3)
      terminal = TERMINAL_STATES.include?(state)
      payload = {
        "schemaVersion" => SCHEMA_VERSION,
        "operation" => operation,
        "runId" => run_id,
        "state" => state,
        "stage" => stage,
        "terminal" => terminal,
        "startedAt" => started_at || (same_run && existing["startedAt"]) || timestamp,
        "heartbeatAt" => timestamp,
        "finishedAt" => terminal ? (finished_at || timestamp) : nil,
        "message" => message,
        "progress" => progress,
        "artifacts" => artifacts || (same_run && existing["artifacts"]),
        "receipt" => receipt,
        "error" => error && { "message" => error.to_s }
      }

      write_atomic(path, payload)
      payload
    end

    def read(path)
      return unless File.file?(path)

      JSON.parse(File.read(path))
    rescue JSON::ParserError
      nil
    end

    def write_atomic(path, payload)
      directory = File.dirname(path)
      FileUtils.mkdir_p(directory)
      temporary = File.join(
        directory,
        ".#{File.basename(path)}.#{Process.pid}.#{SecureRandom.hex(4)}.tmp"
      )
      File.open(temporary, "w", 0o600) do |file|
        file.write(JSON.pretty_generate(payload))
        file.write("\n")
        file.flush
        file.fsync
      end
      File.rename(temporary, path)
    ensure
      FileUtils.rm_f(temporary) if defined?(temporary)
    end
  end

  class Workspace
    attr_reader :ios_root, :workspace_root

    def initialize(ios_root:, runner: CommandRunner.new, env: ENV)
      @ios_root = File.expand_path(ios_root)
      @runner = runner
      @env = env
      @workspace_root = resolve_workspace_root
    end

    def repository_paths
      %w[collector docs homepage ios meta server]
        .map { |name| [name, File.join(workspace_root, name)] }
        .select { |_, path| git_repository?(path) }
        .to_h
    end

    def collector_output_root
      File.expand_path(
        @env.fetch(
          "COMINAVI_COLLECTOR_OUTPUT_ROOT",
          File.join(workspace_root, "collector", "out", "c108-daily")
        )
      )
    end

    def testflight_status_path
      File.expand_path(
        @env.fetch(
          "COMINAVI_OPERATION_STATUS_PATH",
          File.join(ios_root, "build", "fastlane", "operation-status.json")
        )
      )
    end

    private

    def resolve_workspace_root
      override = @env["COMINAVI_WORKSPACE_ROOT"]
      return File.expand_path(override) if override && !override.strip.empty?

      result = @runner.call(
        "git",
        "rev-parse",
        "--path-format=absolute",
        "--git-common-dir",
        chdir: ios_root
      )
      return File.dirname(ios_root) unless result.success?

      File.dirname(File.dirname(result.stdout.strip))
    end

    def git_repository?(path)
      File.directory?(File.join(path, ".git")) || File.file?(File.join(path, ".git"))
    end
  end

  class CrawlerStatus
    LABEL = "io.cominavi.collector.c108"

    def initialize(output_root:, runner: CommandRunner.new, uid: Process.uid, env: ENV)
      @output_root = output_root
      @runner = runner
      @uid = uid
      @env = env
    end

    def call
      cursor_path = File.join(@output_root, "cursor.json")
      cursor = read_json(cursor_path)
      return unavailable("Crawler cursor is unavailable at #{cursor_path}") unless cursor

      pending_until = cursor["pendingUntil"]
      last_until = cursor["lastUntil"]
      run_path = resolve_run_path(cursor, last_until: last_until, pending_until: pending_until)
      run_id = run_path && File.basename(run_path)
      launch = launch_state
      artifacts = artifact_paths(run_path, cursor_path)
      heartbeat = latest_timestamp(artifacts.values.compact + launch.fetch(:paths, []))

      if pending_until
        running_status(
          cursor: cursor,
          run_path: run_path,
          run_id: run_id,
          launch: launch,
          artifacts: artifacts,
          heartbeat: heartbeat
        )
      else
        completed_status(
          cursor: cursor,
          run_path: run_path,
          run_id: run_id,
          launch: launch,
          artifacts: artifacts,
          heartbeat: heartbeat
        )
      end
    rescue JSON::ParserError => error
      unavailable("Crawler state is invalid JSON: #{error.message}")
    end

    private

    def running_status(cursor:, run_path:, run_id:, launch:, artifacts:, heartbeat:)
      summary = read_json(artifacts["summary"])
      receipt = read_json(artifacts["publicationReceipt"])
      state = read_json(artifacts["runState"])
      stage = if receipt
        "committing"
      elsif summary
        "publishing"
      elsif state&.dig("discovery", "status") == "complete"
        "processing"
      else
        "collecting"
      end

      failed = launch[:loaded] && !launch[:running] && launch[:last_exit_status]&.nonzero?
      operation_state = failed ? "failed" : "running"
      message = if failed
        "Crawler exited with status #{launch[:last_exit_status]} while the cursor remains pending."
      else
        "Crawler interval #{cursor['lastUntil']} to #{cursor['pendingUntil']} is #{stage}."
      end

      record(
        run_id: run_id || "#{cursor['lastUntil']}-#{cursor['pendingUntil']}",
        state: operation_state,
        stage: failed ? "failed" : stage,
        started_at: file_timestamp(run_path && File.join(run_path, "state.json")),
        heartbeat_at: heartbeat || cursor["updatedAt"],
        finished_at: failed ? Time.now.utc.iso8601(3) : nil,
        message: message,
        progress: summary,
        artifacts: artifacts,
        receipt: receipt,
        error: failed ? { "message" => message } : nil,
        runtime: launch
      )
    end

    def completed_status(cursor:, run_path:, run_id:, launch:, artifacts:, heartbeat:)
      summary = read_json(artifacts["summary"])
      receipt = read_json(artifacts["publicationReceipt"])
      message = if run_id
        "Crawler run #{run_id} completed and advanced the cursor to #{cursor['lastUntil']}."
      else
        "Crawler is idle; no completed run is recorded."
      end

      record(
        run_id: run_id || "idle",
        state: run_id ? "succeeded" : "idle",
        stage: run_id ? "complete" : "idle",
        started_at: file_timestamp(run_path && File.join(run_path, "state.json")),
        heartbeat_at: heartbeat || cursor["updatedAt"],
        finished_at: summary&.fetch("completed_at", nil) || cursor["updatedAt"],
        message: message,
        progress: summary,
        artifacts: artifacts,
        receipt: receipt,
        error: nil,
        runtime: launch
      )
    end

    def record(
      run_id:,
      state:,
      stage:,
      started_at:,
      heartbeat_at:,
      finished_at:,
      message:,
      progress:,
      artifacts:,
      receipt:,
      error:,
      runtime:
    )
      {
        "schemaVersion" => SCHEMA_VERSION,
        "operation" => "crawler.c108",
        "runId" => run_id,
        "state" => state,
        "stage" => stage,
        "terminal" => TERMINAL_STATES.include?(state),
        "startedAt" => started_at,
        "heartbeatAt" => heartbeat_at,
        "finishedAt" => finished_at,
        "message" => message,
        "progress" => progress,
        "artifacts" => artifacts,
        "receipt" => receipt,
        "error" => error,
        "runtime" => runtime.reject { |key, _| key == :paths }.transform_keys(&:to_s)
      }
    end

    def artifact_paths(run_path, cursor_path)
      {
        "cursor" => cursor_path,
        "run" => run_path,
        "runState" => run_path && File.join(run_path, "state.json"),
        "summary" => run_path && File.join(run_path, "summary.json"),
        "publication" => run_path && File.join(run_path, "publication.json"),
        "snapshotOutbox" => run_path && File.join(run_path, "realtime-snapshot-publication.json"),
        "publicationReceipt" => run_path && File.join(run_path, "realtime-snapshot-receipt.json")
      }.transform_values { |path| path if path && File.exist?(path) }
    end

    def resolve_run_path(cursor, last_until:, pending_until:)
      recorded = cursor["lastRun"]
      if pending_until
        expected = File.join(@output_root, "runs", "#{last_until}-#{pending_until}")
        return expected if File.directory?(expected)
      end
      return recorded if recorded && File.directory?(recorded)

      Dir.glob(File.join(@output_root, "runs", "*")).select { |path| File.directory?(path) }.max
    end

    def launch_state
      return { loaded: nil, running: nil, pid: nil, last_exit_status: nil, paths: [] } if @env["COMINAVI_SKIP_LAUNCHCTL"] == "1"

      result = @runner.call("launchctl", "print", "gui/#{@uid}/#{LABEL}")
      return { loaded: false, running: false, pid: nil, last_exit_status: nil, paths: [] } unless result.success?

      output = result.stdout
      {
        loaded: true,
        running: output.match?(/^\s*state = running$/),
        pid: output[/^\s*pid = (\d+)$/, 1]&.to_i,
        last_exit_status: output[/^\s*last exit code = (-?\d+)$/, 1]&.to_i,
        paths: []
      }
    end

    def unavailable(message)
      {
        "schemaVersion" => SCHEMA_VERSION,
        "operation" => "crawler.c108",
        "runId" => "unavailable",
        "state" => "unknown",
        "stage" => "unavailable",
        "terminal" => false,
        "startedAt" => nil,
        "heartbeatAt" => nil,
        "finishedAt" => nil,
        "message" => message,
        "progress" => nil,
        "artifacts" => nil,
        "receipt" => nil,
        "error" => { "message" => message },
        "runtime" => nil
      }
    end

    def read_json(path)
      return unless path && File.file?(path)

      JSON.parse(File.read(path))
    end

    def file_timestamp(path)
      return unless path && File.exist?(path)

      File.mtime(path).utc.iso8601(3)
    end

    def latest_timestamp(paths)
      times = paths.map { |path| File.mtime(path) if File.exist?(path) }.compact
      times.max&.utc&.iso8601(3)
    end
  end

  class TestFlightStatus
    def initialize(path:)
      @path = path
    end

    def call
      status = StatusRecord.read(@path)
      return status.merge("artifacts" => merge_status_path(status["artifacts"])) if status

      if File.file?(@path)
        return {
          "schemaVersion" => SCHEMA_VERSION,
          "operation" => "testflight.release",
          "runId" => "invalid",
          "state" => "unknown",
          "stage" => "unavailable",
          "terminal" => false,
          "startedAt" => nil,
          "heartbeatAt" => File.mtime(@path).utc.iso8601(3),
          "finishedAt" => nil,
          "message" => "TestFlight release status is invalid JSON.",
          "progress" => nil,
          "artifacts" => { "status" => @path },
          "receipt" => nil,
          "error" => { "message" => "Invalid JSON at #{@path}." }
        }
      end

      {
        "schemaVersion" => SCHEMA_VERSION,
        "operation" => "testflight.release",
        "runId" => "idle",
        "state" => "idle",
        "stage" => "idle",
        "terminal" => false,
        "startedAt" => nil,
        "heartbeatAt" => nil,
        "finishedAt" => nil,
        "message" => "No TestFlight release status has been recorded.",
        "progress" => nil,
        "artifacts" => { "status" => @path },
        "receipt" => nil,
        "error" => nil
      }
    end

    private

    def merge_status_path(artifacts)
      (artifacts || {}).merge("status" => @path)
    end
  end

  class Waiter
    def initialize(status_provider:, timeout_seconds:, interval_seconds:, clock: Time, sleeper: Kernel)
      @status_provider = status_provider
      @timeout_seconds = timeout_seconds
      @interval_seconds = interval_seconds
      @clock = clock
      @sleeper = sleeper
    end

    def call
      deadline = @clock.now + @timeout_seconds
      loop do
        status = @status_provider.call
        return [status, true] if status["terminal"]
        return [status.merge("message" => "Timed out waiting: #{status['message']}"), false] if @clock.now >= deadline

        @sleeper.sleep(@interval_seconds)
      end
    end
  end

  class Doctor
    Check = Struct.new(:name, :status, :summary, :details)

    def initialize(workspace:, runner: CommandRunner.new, remote: true, env: ENV)
      @workspace = workspace
      @runner = runner
      @remote = remote
      @env = env
    end

    def call
      checks = []
      checks.concat(repository_checks)
      checks << git_metadata_check
      checks.concat(tool_checks)
      checks << fastlane_dependencies_check
      checks << asc_key_check
      checks << xcode_check
      checks << simulator_check
      checks << crawler_check
      checks.concat(remote_checks) if @remote

      status = if checks.any? { |check| check.status == "fail" }
        "fail"
      elsif checks.any? { |check| check.status == "warn" }
        "warn"
      else
        "pass"
      end
      {
        "schemaVersion" => SCHEMA_VERSION,
        "status" => status,
        "remoteChecks" => @remote,
        "workspaceRoot" => @workspace.workspace_root,
        "iosRoot" => @workspace.ios_root,
        "checkedAt" => Time.now.utc.iso8601(3),
        "checks" => checks.map do |check|
          {
            "name" => check.name,
            "status" => check.status,
            "summary" => check.summary,
            "details" => check.details
          }
        end
      }
    end

    private

    def repository_checks
      repositories = @workspace.repository_paths.to_a
      source_ios = @workspace.repository_paths["ios"]
      if source_ios && File.expand_path(source_ios) != @workspace.ios_root
        repositories << ["ios-worktree", @workspace.ios_root]
      end

      repositories.map do |name, path|
        result = @runner.call("git", "status", "--porcelain=v1", "--branch", chdir: path)
        if !result.success?
          Check.new("repo.#{name}", "fail", "Git status failed.", compact(result.stderr))
        else
          lines = result.stdout.lines.map(&:strip)
          dirty = lines.drop(1).any?
          Check.new(
            "repo.#{name}",
            dirty ? "warn" : "pass",
            dirty ? "Repository has local changes." : "Repository is clean.",
            lines.first
          )
        end
      end
    end

    def git_metadata_check
      result = @runner.call(
        "git",
        "rev-parse",
        "--path-format=absolute",
        "--git-common-dir",
        chdir: @workspace.ios_root
      )
      return Check.new("git.metadata", "fail", "Git common directory could not be resolved.", compact(result.stderr)) unless result.success?

      path = result.stdout.strip
      writable = File.writable?(path)
      Check.new(
        "git.metadata",
        writable ? "pass" : "warn",
        writable ? "Shared Git metadata is writable by the current user." : "Shared Git metadata is not writable in this execution context.",
        path
      )
    end

    def tool_checks
      required = %w[git ruby jq xcodebuild xcrun gh fastlane]
      required << "pnpm" if @workspace.repository_paths.key?("server")
      required.map do |tool|
        result = @runner.call("sh", "-c", "command -v #{tool}")
        Check.new(
          "tool.#{tool}",
          result.success? ? "pass" : "fail",
          result.success? ? "Available." : "Required command is unavailable.",
          compact(result.stdout.empty? ? result.stderr : result.stdout)
        )
      end
    end

    def fastlane_dependencies_check
      result = @runner.call("bundle", "check", chdir: @workspace.ios_root)
      if result.success?
        return Check.new(
          "fastlane.dependencies",
          "pass",
          "Locked Ruby dependencies are installed for Bundler.",
          compact(result.stdout)
        )
      end

      locked = File.read(File.join(@workspace.ios_root, "Gemfile.lock"))[/^    fastlane \(([^)]+)\)$/, 1]
      installed = @runner.call("fastlane", "--version")
      installed_version = installed.stdout[/fastlane (\d+(?:\.\d+)+)/, 1]
      matches = installed.success? && locked && installed_version == locked
      Check.new(
        "fastlane.dependencies",
        matches ? "pass" : "fail",
        matches ? "Installed Fastlane #{installed_version} matches Gemfile.lock." : "Install the locked Fastlane #{locked || 'version'} with bundle install.",
        matches ? "Using #{installed.stdout.lines.first.to_s.strip}" : compact(result.stderr)
      )
    end

    def asc_key_check
      path = asc_key_path
      unless File.file?(path) && File.readable?(path)
        return Check.new("auth.app_store_connect.local", "fail", "App Store Connect API key is not readable.", path)
      end

      permissions = File.stat(path).mode & 0o777
      status = (permissions & 0o077).zero? ? "pass" : "fail"
      Check.new(
        "auth.app_store_connect.local",
        status,
        status == "pass" ? "API key is present with private permissions." : "API key permissions must be 600.",
        "#{path} (#{format('%03o', permissions)})"
      )
    end

    def xcode_check
      result = @runner.call("xcodebuild", "-version")
      Check.new(
        "xcode.installation",
        result.success? ? "pass" : "fail",
        result.success? ? "Xcode command-line tools are available." : "Xcode is unavailable.",
        compact(result.stdout.empty? ? result.stderr : result.stdout)
      )
    end

    def simulator_check
      result = @runner.call("xcrun", "simctl", "list", "devices", "available", "-j")
      count = result.success? ? JSON.parse(result.stdout).fetch("devices", {}).values.flatten.length : 0
      status = result.success? && count.positive? ? "pass" : "fail"
      Check.new(
        "xcode.simulator",
        status,
        status == "pass" ? "#{count} simulator devices are available." : "No usable simulator runtime was discovered.",
        status == "pass" ? nil : compact(result.stderr)
      )
    rescue JSON::ParserError => error
      Check.new("xcode.simulator", "fail", "Simulator inventory returned invalid JSON.", error.message)
    end

    def crawler_check
      status = CrawlerStatus.new(
        output_root: @workspace.collector_output_root,
        runner: @runner,
        env: @env
      ).call
      level = %w[failed unknown].include?(status["state"]) ? "warn" : "pass"
      Check.new("operation.crawler", level, status["message"], status["stage"])
    end

    def remote_checks
      [github_check, app_store_connect_check, cloudflare_check].compact
    end

    def github_check
      expected = @env.fetch("COMINAVI_GITHUB_LOGIN", "GalvinGao")
      auth = @runner.call("gh", "auth", "status", "--active", "--hostname", "github.com")
      return Check.new("auth.github", "fail", "GitHub CLI authentication is unavailable.", compact(auth.stderr)) unless auth.success?

      api = @runner.call("gh", "api", "user", "--jq", ".login")
      return Check.new("auth.github", "fail", "GitHub API access failed.", compact(api.stderr)) unless api.success?

      actual = api.stdout.strip
      Check.new(
        "auth.github",
        actual == expected ? "pass" : "fail",
        actual == expected ? "Authenticated as #{actual}." : "Expected #{expected}, authenticated as #{actual}.",
        nil
      )
    end

    def app_store_connect_check
      command = fastlane_command + %w[ios asc_check]
      result = @runner.call(
        *command,
        chdir: @workspace.ios_root,
        env: {
          "ASC_KEY_FILEPATH" => asc_key_path,
          "FASTLANE_SKIP_UPDATE_CHECK" => "1"
        }
      )
      Check.new(
        "auth.app_store_connect.remote",
        result.success? ? "pass" : "fail",
        result.success? ? "App Store Connect API access is verified." : "App Store Connect API access failed.",
        compact(result.success? ? result.stdout.lines.grep(/Connected to App Store Connect/).last : result.stderr)
      )
    end

    def cloudflare_check
      server = @workspace.repository_paths["server"]
      return unless server

      wrangler_configuration = File.join(server, "wrangler.jsonc")
      expected_account_id = if File.file?(wrangler_configuration)
        File.read(wrangler_configuration)[/"account_id"\s*:\s*"([^"]+)"/, 1]
      end
      ci = @env["CI"] && !@env["CI"].strip.empty?
      headless_environment = %w[CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID].all? do |key|
        @env[key] && !@env[key].strip.empty?
      end
      result = @runner.call("pnpm", "exec", "wrangler", "whoami", chdir: server)
      authenticated = result.success? && expected_account_id && result.stdout.include?(expected_account_id)
      status = if authenticated && (!ci || headless_environment)
        "pass"
      else
        "fail"
      end
      summary = if !result.success?
        "Wrangler authentication failed."
      elsif !expected_account_id
        "The server Cloudflare account ID is not configured."
      elsif !authenticated
        "Wrangler is not authenticated for the server's configured Cloudflare account."
      elsif ci && !headless_environment
        "CI requires CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID."
      elsif headless_environment
        "Headless Wrangler authentication is verified for the configured account."
      else
        "Stored Wrangler authentication is verified for the configured account; CI uses token environment variables."
      end
      Check.new(
        "auth.cloudflare",
        status,
        summary,
        expected_account_id
      )
    end

    def env_example_value(key)
      path = File.join(@workspace.ios_root, "fastlane", ".env.example")
      return unless File.file?(path)

      File.foreach(path) do |line|
        match = line.chomp.match(/\A#{Regexp.escape(key)}=(.+)\z/)
        return match[1].strip if match
      end
      nil
    end

    def asc_key_path
      override = @env["ASC_KEY_FILEPATH"]
      return File.expand_path(override) if override && !override.strip.empty?

      key_id = @env["ASC_KEY_ID"] || env_example_value("ASC_KEY_ID")
      local = File.join(@workspace.ios_root, "fastlane", "AuthKey_#{key_id}.p8")
      return local if File.file?(local)

      source_ios = @workspace.repository_paths["ios"]
      source_ios ? File.join(source_ios, "fastlane", "AuthKey_#{key_id}.p8") : local
    end

    def fastlane_command
      bundled = @runner.call("bundle", "check", chdir: @workspace.ios_root)
      bundled.success? ? %w[bundle exec fastlane] : ["fastlane"]
    end

    def compact(value)
      value.to_s.lines.map(&:strip).reject(&:empty?).last(4).join(" | ")
    end
  end
end
