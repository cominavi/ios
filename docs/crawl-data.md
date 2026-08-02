# Crawl data integration

ComiNavi uses three catalog modes in debug and staging builds:

| Mode | Catalog and placement | Circle artwork | Tags | Social and shinagaki |
| --- | --- | --- | --- | --- |
| Circle.ms | Live, authoritative database selected from the Circle.ms event API | Live Circle.ms image database | Circle.ms query API | Bundled crawl enrichment when the event matches |
| Demo data | Frozen C104 Circle.ms-format database | Bundled C104 image database | None | None |
| Crawl data | Bundled C108 placement seed from the collector | No circle cuts | Extracted from the bundled crawl archive | Bundled X profile, post, confidence, and media URLs |

The crawl archive is enrichment, not an authority for circle identity. Matches
join to `ComiketCircleExtend.WCId`, which is stable across Web Catalog database
revisions. The bundled C108 seed's local circle ID is used only as a fallback.
When a post has several placement candidates, the app retains only candidates
tied for the collector's strongest score and displays the placement confidence.

Refresh the bundled non-production source after running the collector:

```sh
Scripts/prepare-crawl-catalog.sh
```

The script copies the C108 seed database and `selected-posts.json`, then creates
an empty, schema-valid image database. Shinagaki media stays at its HTTPS source
and is cached by iOS instead of adding the collector's full media archive to the
application bundle.
