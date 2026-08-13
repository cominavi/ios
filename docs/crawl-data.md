# Crawl enrichment integration

ComiNavi has one C108 catalog authority: the database downloaded from
Circle.ms. Collector output is bundled only as optional social and shinagaki
enrichment for the matching event.

| Mode | Catalog and placement | Circle artwork | Tags | Social and shinagaki |
| --- | --- | --- | --- | --- |
| Circle.ms | Live, authoritative database selected from the Circle.ms event API | Live Circle.ms image database | Circle.ms query API | Bundled crawl enrichment when the event matches |
| Demo data | Frozen C104 Circle.ms-format database for debug and staging | Bundled C104 image database | None | None |

There is no standalone crawl-data catalog mode and no bundled C108 placement or
image database. Matches join the live `ComiketCircleExtend` rows by `WCId`,
which remains stable across Web Catalog database revisions. A crawl match that
cannot resolve through that public identifier is omitted rather than attached
to a mutable local circle ID.

Refresh the bundled enrichment after running the collector:

```sh
Scripts/prepare-crawl-catalog.sh
```

The script validates the compact export against the collector's authoritative
C108 seed database before publishing `crawl-c108-shinagaki.json` alongside the
compact `crawl-c108-ocr-search.json` search sidecar. The sidecar includes text
from the collector enrichment archive only when the individual OCR line has at
least 0.80 confidence. The app uses that text only as a low-weight local search
signal. Publication requires complete post provenance, exact
`(comiket_no, circle_id, wc_id)` resolution, unique WCId ownership, and
Circle.ms provenance bound to the seed database digest. Shinagaki media stays
at its HTTPS source and is cached by iOS instead of being copied into the
application bundle.
