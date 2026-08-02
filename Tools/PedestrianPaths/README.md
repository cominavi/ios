# Authoring Big Sight walking paths in JOSM

JOSM is the source editor for ComiNavi's walkable path network. The app does
not read JOSM files at runtime: the checked-in `.osm` file is converted to the
bundled `BigSightPedestrianWays.geojson` during development, so routes remain
available offline.

## Set up the layers

1. In JOSM, download the Tokyo Big Sight area from OpenStreetMap into a
   reference layer.
2. Open `BigSightWalkways.template.osm`, then **Save As**
   `BigSightWalkways.osm` in this directory.
3. Keep the downloaded OpenStreetMap layer visible, but activate the local
   `BigSightWalkways.osm` layer before drawing.
4. Do not remove `upload='never'` from the opening `<osm>` element. These paths
   may describe event-specific or privately verified indoor circulation and
   must not be accidentally uploaded to public OpenStreetMap.

## Draw routable centerlines

- Draw one connected way through the center of each usable aisle or walkway.
- Reuse the same node wherever two paths intersect. Merely crossing two lines
  without a shared node does not create a reliable intersection.
- End each hall path at a realistic entrance or transition point. Connect
  stairs to the walkways on both ends.
- Prefer a few accurate connected lines over many disconnected decorative
  traces.

Add these tags to every path that ComiNavi should import:

| Key | Walkway | Stairs | Notes |
| --- | --- | --- | --- |
| `highway` | `footway` | `steps` | Required |
| `cominavi:route` | `yes` | `yes` | Includes a local path without downloaded site polygons |
| `level` | e.g. `1` | e.g. `1;2` | Strongly recommended indoors |
| `indoor` | `yes` when applicable | `yes` when applicable | Optional |
| `covered` | `yes` when applicable | `yes` when applicable | Optional |
| `name` | Human-readable name | Human-readable name | Optional |

Paths tagged `access=private`, `access=no`, `footway=sidewalk`,
`footway=crossing`, or `area=yes` are deliberately excluded.

## Regenerate the bundled route network

From the iOS repository root:

```sh
ruby Scripts/generate-bigsight-pedestrian-ways.rb \
  Tools/PedestrianPaths/BigSightWalkways.osm \
  ComiNavi/Resources/MapData/BigSightPedestrianWays.geojson
```

The command reports the number of imported ways. Rebuild the app afterward;
no user download or network connection is required.

Run the converter regression test after changing the import rules:

```sh
ruby Scripts/test-generate-bigsight-pedestrian-ways.rb
```

Before replacing the production GeoJSON, zoom into every intersection in JOSM,
run JOSM's data validator, and check that entrances, stairs, and corridor
junctions use shared nodes.
