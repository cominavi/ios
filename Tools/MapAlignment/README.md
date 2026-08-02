# Venue map alignment tool

This local tool overlays authored venue images from a Circle.ms SQLite database
on OpenStreetMap. It lets you move, resize, and rotate each venue independently,
then saves the result for implementation in the iOS app. C104 uses the bundled
demo database; C108 automatically uses the newest downloaded simulator shard.

Run it from the repository root:

```sh
python3 Tools/MapAlignment/server.py --event 108
```

Open <http://127.0.0.1:8765>, align the venues, and choose **Save to repo**.
The result is written to `Tools/MapAlignment/calibration-c108.json`. Use
`--event 104` to reopen the original calibration, which continues to save to
`Tools/MapAlignment/calibration.json`. A database outside the simulator can be
selected with `--image-database PATH`.

Controls:

- Drag the center handle to move a venue.
- Drag any corner to edit its width and height.
- Drag the round rotation handle above the venue to rotate it.
- Use arrow keys for 25 cm position nudges. Hold Shift for 1 m nudges.
- Use `[` and `]` for 0.1 degree rotation nudges. Hold Shift for 1 degree.
- Use the numeric fields for exact values.

The page uses MapLibre GL JS from unpkg and OpenStreetMap raster tiles. The
venue artwork remains local and is read directly from the demo SQLite database.
