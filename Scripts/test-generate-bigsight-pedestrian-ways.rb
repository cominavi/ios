#!/usr/bin/env ruby

require "json"
require "minitest/autorun"
require "open3"
require "tempfile"

class GenerateBigSightPedestrianWaysTest < Minitest::Test
  def test_imports_explicit_local_route_without_downloaded_site_boundaries
    Tempfile.create(["cominavi-pedestrian-ways", ".geojson"]) do |output|
      script = File.expand_path("generate-bigsight-pedestrian-ways.rb", __dir__)
      fixture = File.expand_path("Fixtures/PedestrianWays/local-authoring.osm", __dir__)
      _stdout, stderr, status = Open3.capture3("ruby", script, fixture, output.path)

      assert status.success?, stderr
      collection = JSON.parse(File.read(output.path))
      assert_equal 1, collection.fetch("features").length
      feature = collection.fetch("features").first
      assert_equal(-10, feature.dig("properties", "osm_id"))
      assert_equal true, feature.dig("properties", "locally_authored")
      assert_equal "Locally authored aisle", feature.dig("properties", "name")
      assert_equal [-1, -2], feature.dig("properties", "node_refs")
    end
  end
end
