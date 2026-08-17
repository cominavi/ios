# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/cominavi_operations"

class CominaviOperationsTest < Minitest::Test
  def test_status_record_preserves_start_and_finishes_atomically
    Dir.mktmpdir do |directory|
      path = File.join(directory, "status.json")
      started = Time.utc(2026, 8, 17, 1, 2, 3)
      finished = Time.utc(2026, 8, 17, 1, 3, 4)

      CominaviOperations::StatusRecord.write(
        path: path,
        operation: "testflight.release",
        run_id: "release-1",
        state: "running",
        stage: "building",
        message: "Building",
        now: started
      )
      result = CominaviOperations::StatusRecord.write(
        path: path,
        operation: "testflight.release",
        run_id: "release-1",
        state: "succeeded",
        stage: "complete",
        message: "Complete",
        now: finished,
        receipt: { "buildNumber" => "42" }
      )

      assert_equal "2026-08-17T01:02:03.000Z", result.fetch("startedAt")
      assert_equal "2026-08-17T01:03:04.000Z", result.fetch("finishedAt")
      assert result.fetch("terminal")
      assert_equal result, JSON.parse(File.read(path))
      assert_empty Dir.glob(File.join(directory, ".*.tmp"))
    end
  end

  def test_status_record_does_not_reuse_timestamps_across_runs
    Dir.mktmpdir do |directory|
      path = File.join(directory, "status.json")
      CominaviOperations::StatusRecord.write(
        path: path,
        operation: "testflight.release",
        run_id: "release-1",
        state: "succeeded",
        stage: "complete",
        message: "Old release",
        now: Time.utc(2026, 8, 17, 1, 0, 0)
      )
      result = CominaviOperations::StatusRecord.write(
        path: path,
        operation: "testflight.release",
        run_id: "release-2",
        state: "running",
        stage: "preparing",
        message: "New release",
        now: Time.utc(2026, 8, 17, 2, 0, 0)
      )

      assert_equal "2026-08-17T02:00:00.000Z", result.fetch("startedAt")
      assert_nil result.fetch("finishedAt")
      refute result.fetch("terminal")
    end
  end

  def test_crawler_status_reports_publishing_from_durable_artifacts
    Dir.mktmpdir do |directory|
      run = File.join(directory, "runs", "100-200")
      FileUtils.mkdir_p(run)
      File.write(
        File.join(directory, "cursor.json"),
        JSON.generate(
          "schemaVersion" => 1,
          "lastUntil" => 100,
          "pendingUntil" => 200,
          "lastRun" => run,
          "updatedAt" => "2026-08-17T01:00:00Z"
        )
      )
      File.write(File.join(run, "state.json"), JSON.generate("discovery" => { "status" => "complete" }))
      File.write(File.join(run, "summary.json"), JSON.generate("mode" => "complete"))

      result = CominaviOperations::CrawlerStatus.new(
        output_root: directory,
        env: { "COMINAVI_SKIP_LAUNCHCTL" => "1" }
      ).call

      assert_equal "running", result.fetch("state")
      assert_equal "publishing", result.fetch("stage")
      refute result.fetch("terminal")
      assert_equal "100-200", result.fetch("runId")
      assert_equal File.join(run, "summary.json"), result.dig("artifacts", "summary")
    end
  end

  def test_crawler_status_reports_completed_cursor_and_receipt
    Dir.mktmpdir do |directory|
      run = File.join(directory, "runs", "100-200")
      FileUtils.mkdir_p(run)
      File.write(
        File.join(directory, "cursor.json"),
        JSON.generate(
          "schemaVersion" => 1,
          "lastUntil" => 200,
          "pendingUntil" => nil,
          "lastRun" => run,
          "updatedAt" => "2026-08-17T01:04:00Z"
        )
      )
      File.write(File.join(run, "state.json"), "{}")
      File.write(
        File.join(run, "summary.json"),
        JSON.generate("mode" => "complete", "completed_at" => "2026-08-17T01:03:00Z")
      )
      File.write(
        File.join(run, "realtime-snapshot-receipt.json"),
        JSON.generate("generation" => 12, "publicationCursor" => 50)
      )

      result = CominaviOperations::CrawlerStatus.new(
        output_root: directory,
        env: { "COMINAVI_SKIP_LAUNCHCTL" => "1" }
      ).call

      assert_equal "succeeded", result.fetch("state")
      assert_equal "complete", result.fetch("stage")
      assert result.fetch("terminal")
      assert_equal 12, result.dig("receipt", "generation")
      assert_equal "2026-08-17T01:03:00Z", result.fetch("finishedAt")
    end
  end

  def test_testflight_status_has_idle_contract_before_first_release
    Dir.mktmpdir do |directory|
      path = File.join(directory, "missing.json")
      result = CominaviOperations::TestFlightStatus.new(path: path).call

      assert_equal 1, result.fetch("schemaVersion")
      assert_equal "testflight.release", result.fetch("operation")
      assert_equal "idle", result.fetch("state")
      refute result.fetch("terminal")
      assert_equal path, result.dig("artifacts", "status")
    end
  end

  def test_testflight_status_reports_corrupt_file
    Dir.mktmpdir do |directory|
      path = File.join(directory, "status.json")
      File.write(path, "{")
      result = CominaviOperations::TestFlightStatus.new(path: path).call

      assert_equal "unknown", result.fetch("state")
      assert_equal "unavailable", result.fetch("stage")
      assert_match(/Invalid JSON/, result.dig("error", "message"))
    end
  end
end
