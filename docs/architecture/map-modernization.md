# Map modernization

## Current evidence

The C104 catalog contains 6,093 physical table placements, 23,858 circle records, and roughly 97 MB of circle-cut image blobs. The existing startup path reads every circle and writes every image blob to a separate PNG before the user can use the app. The current map then ignores the coordinate tables and displays one bitmap inside a UIKit scroll view.

The official layout coordinates use the high-resolution map coordinate system. For example, the East 1–3 map is 4,680 × 1,680 map units and each physical table is 40 × 40 units. `layout` determines which half contains the `a` circle:

- `1`: left
- `2`: bottom
- `3`: right
- `4`: top

## Target modules

1. **Catalog repository** — a deep interface over the read-only main and image databases. It returns Sendable domain values and keeps GRDB, joins, query cancellation, and blob loading local.
2. **Map screen model** — a `@MainActor @Observable` owner for day, venue, loading, selection, search, and overlay state. It never owns database records.
3. **Vector map canvas** — a stateless renderer plus transient camera state. It draws only visible tables and resolves taps by inverting the camera transform.
4. **User plan store** — a later writable database for bookmarks, colors, route ordering, and synchronization metadata. Official catalog databases remain read-only.

The repository seam has two adapters from the start: SQLite for the app and an in-memory fixture for deterministic UI tests.

## Delivery sequence

1. Replace the static map with the full-screen vector table scene, inertial pan/zoom/rotation, circle hit testing, and a lazy detail sheet.
2. Query visible circle summaries after camera motion settles; fetch image blobs only above the seven-table zoom threshold and evict decoded images outside the viewport.
3. Add indexed search and highlights. If the official database cannot satisfy the query efficiently, build a small derived FTS/R-tree cache keyed by the catalog digest.
4. Add genre, bookmark, route, and color overlays to the same renderer without duplicating geometry.
5. Move bookmarks and sync state into the user plan store, with deterministic conflict and ordering tests.
6. Profile a representative long session on a physical device and enforce CPU, memory, hitch, and background-work budgets.

## Performance invariants

- No catalog-wide image extraction.
- No image blobs in map-scene queries.
- No SQLite records cross into SwiftUI views.
- Camera motion does not issue a query for every frame.
- The renderer culls geometry outside the visible map rectangle.
- Decoded circle images exist only for the close-zoom viewport and selected detail.
- Official databases are opened read-only and replaced atomically when their digest changes.

## Implemented architecture

- `SQLiteMapCatalog` is the only map-facing adapter for the official read-only databases. SwiftUI receives small Sendable domain values, never GRDB records.
- `MapCatalogIndex` lazily derives a digest-keyed 5 MB cache on the first close-zoom or search request. Its R-tree drives viewport queries and its trigram FTS index supports Japanese and Latin substring search. It is not part of launch initialization.
- `MapScreenModel` is a main-actor `@Observable` state owner with separate cancellable tasks for scene, selection, viewport artwork, search, genre, local plan writes, and remote synchronization.
- `InteractiveMapCanvas` renders coordinate-derived table geometry, subspace dividers, block labels, search/genre/bookmark overlays, route lines, stop badges, and close-zoom artwork. Pan, magnification, and rotation are transient gesture state; committed camera changes alone schedule viewport work.
- `SQLiteUserPlanStore` keeps local route order, colors, memo fields, and sync state in Application Support. Catalog databases remain immutable.
- `BookmarkSyncCoordinator` merges remote Circle.ms favorites without overwriting pending local mutations, then flushes upserts and tombstones. Local interaction never waits for the network.
- The app and test targets compile in Swift 6 mode. Shared app-shell state uses Observation; typed Sendable request and response models replace `[String: Any]` at Alamofire concurrency boundaries.

## Verification snapshot

- The C104 derived cache contains 23,858 placements and 23,858 FTS documents.
- A real authenticated probe returned 594 placements for a representative viewport and 18 matches for a Japanese trigram query.
- The same probe completed cache creation plus both queries in about 140 ms on the iPhone 17 Pro Max simulator; subsequent queries reuse the digest-keyed cache.
- Decoded map artwork is capped by a 24 MB `NSCache` cost limit and discarded from visible state when zoom drops below the artwork threshold.
- The renderer has no timeline or display-link loop, so an idle map schedules no frames or database queries.
- Simulator runtime logs show no app Metal/GPU faults. Physical-device Energy Log and long-session thermal validation remain a release qualification step because simulator energy numbers are not representative.
