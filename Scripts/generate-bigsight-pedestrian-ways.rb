#!/usr/bin/env ruby

require "json"
require "date"
require "rexml/document"

input_path, output_path = ARGV
abort "usage: #{$PROGRAM_NAME} INPUT.osm OUTPUT.geojson" unless input_path && output_path

document = REXML::Document.new(File.read(input_path))
nodes = {}
REXML::XPath.each(document, "/osm/node") do |node|
  nodes[node.attributes["id"]] = [
    node.attributes["lon"].to_f,
    node.attributes["lat"].to_f,
  ]
end

ways = []
REXML::XPath.each(document, "/osm/way") do |way|
  tags = {}
  way.elements.each("tag") { |tag| tags[tag.attributes["k"]] = tag.attributes["v"] }
  node_refs = way.get_elements("nd").map { |node| node.attributes["ref"] }
  resolved_nodes = node_refs.each_with_object([]) do |node_ref, resolved|
    coordinate = nodes[node_ref]
    resolved << [node_ref, coordinate] if coordinate
  end
  ways << {
    id: way.attributes["id"].to_i,
    tags: tags,
    node_refs: resolved_nodes.map { |node_ref, _coordinate| node_ref.to_i },
    coordinates: resolved_nodes.map { |_node_ref, coordinate| coordinate },
  }
end

def point_in_polygon?(point, polygon)
  x, y = point
  contained = false
  polygon.each_with_index do |start, index|
    finish = polygon[(index + 1) % polygon.length]
    crosses = (start[1] > y) != (finish[1] > y)
    next unless crosses

    boundary_x = (finish[0] - start[0]) * (y - start[1]) /
      (finish[1] - start[1]) + start[0]
    contained = !contained if x < boundary_x
  end
  contained
end

# OpenStreetMap relation 7743566 (Tokyo Big Sight) consists of these two
# commercial-landuse outer ways. They keep nearby station and promenade noise
# out of the venue overlay.
site_boundary_ids = [541_645_263, 541_645_262]
site_polygons = ways
  .select { |way| site_boundary_ids.include?(way[:id]) }
  .map { |way| way[:coordinates] }

# The calibrated maps cover these OSM building footprints. An otherwise
# unclassified dedicated footway is useful when it physically enters one of
# these buildings, even when it lacks indoor or level tags.
venue_building_ids = [
  154_080_988, # Conference Tower
  154_080_995, # West Halls
  181_086_812, # Entrance Plaza connector
  543_048_841, # East Halls
  577_366_022, # New East Halls
  740_163_677, # South Halls
]
venue_polygons = ways
  .select { |way| venue_building_ids.include?(way[:id]) }
  .map { |way| way[:coordinates] }

features = ways.each_with_object([]) do |way, selected|
  tags = way[:tags]
  highway = tags["highway"]
  next unless ["footway", "steps"].include?(highway)
  next unless way[:coordinates].length >= 2
  next if ["sidewalk", "crossing"].include?(tags["footway"])
  next if ["no", "private"].include?(tags["access"])
  next if tags["area"] == "yes"

  on_site = way[:coordinates].any? do |coordinate|
    site_polygons.any? { |polygon| point_in_polygon?(coordinate, polygon) }
  end
  in_venue = way[:coordinates].any? do |coordinate|
    venue_polygons.any? { |polygon| point_in_polygon?(coordinate, polygon) }
  end
  explicitly_routable = tags.key?("indoor") || tags.key?("level") || tags["covered"] == "yes"
  locally_authored = ["yes", "designated", "preferred"].include?(tags["cominavi:route"])
  next unless locally_authored || in_venue || (on_site && (explicitly_routable || highway == "steps"))

  selected << {
    type: "Feature",
    id: "way/#{way[:id]}",
    properties: {
      osm_id: way[:id],
      kind: highway,
      level: tags["level"],
      indoor: tags["indoor"] == "yes" || tags["indoor"] == "1",
      covered: tags["covered"] == "yes",
      name: tags["name"],
      locally_authored: locally_authored,
      node_refs: way[:node_refs],
    }.compact,
    geometry: {
      type: "LineString",
      coordinates: way[:coordinates],
    },
  }
end.sort_by { |feature| feature[:properties][:osm_id] }

collection = {
  type: "FeatureCollection",
  metadata: {
    source: "OpenStreetMap contributors",
    source_url: "https://www.openstreetmap.org/copyright",
    generated_on: Date.today.iso8601,
    site_relation: 7_743_566,
    filter: "footway or steps; no sidewalk/crossing/private/no; venue footprint, explicit on-site indoor/level/covered, or cominavi:route=yes",
  },
  features: features,
}

File.write(output_path, JSON.pretty_generate(collection) + "\n")
warn "wrote #{features.length} pedestrian ways to #{output_path}"
