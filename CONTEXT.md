# ComiNavi domain language

- **Catalog** — the downloaded Circle.ms SQLite databases for one Comiket event.
- **Catalog event** — one externally viewable event returned by Circle.ms `GetEventList`, identified by both a stable API event ID and a public Comiket number.
- **Catalog library** — the app-level module that discovers Circle.ms-supported events, remembers the selected event, and owns the lifecycle of the one active catalog data source.
- **Event shard** — the on-device namespace `event-{event ID}/comiket-{number}` containing one event's replaceable catalog caches and per-user persistent route plan.
- **Map scene** — the vector-ready geometry and metadata for one event day and venue map.
- **Campus overview** — the north-up, GPS-projected Tokyo Big Sight view that places every available venue map at a shared physical scale.
- **Venue anchor** — a representative WGS84 building position; East 1–3 and East 4–6 use diagram-derived offsets inside their shared building footprint.
- **Campus connection** — a vector walking path between venues, reconstructed from the official Galleria, concourse, link-space, and connecting-bridge diagrams.
- **Table** — one physical desk placement from `ComiketLayoutWC`; it can contain an `a` and a `b` circle space.
- **Circle space** — one participating circle assigned to one half of a table for a specific day.
- **Camera** — the transient map viewport transform: pan, zoom, and rotation.
- **Overlay** — optional map-aligned information such as genres, search matches, bookmarks, or route colors.
- **Catalog repository** — the deep module that answers map-scene, circle-detail, search, image, and synchronization queries without exposing SQLite records to views.
