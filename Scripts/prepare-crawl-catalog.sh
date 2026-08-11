#!/bin/sh

set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_directory=$(CDPATH= cd -- "${script_directory}/.." && pwd)
collector_directory=${1:-"${project_directory}/../collector"}
shinagaki_input=${2:-"${collector_directory}/out/c108-enriched/selected-posts.json"}
destination="${project_directory}/ComiNavi/Resources/CrawlCatalogs/C108"
catalog_source="${collector_directory}/out/catalog-seed/webcatalog108.db"

if [ -d "${shinagaki_input}" ]; then
    shinagaki_source="${shinagaki_input}/selected-posts.json"
else
    shinagaki_source="${shinagaki_input}"
fi

if [ ! -f "${catalog_source}" ]; then
    echo "Missing authoritative catalog used to validate crawl enrichment: ${catalog_source}" >&2
    exit 1
fi

if [ ! -f "${shinagaki_source}" ]; then
    echo "Missing crawl enrichment: ${shinagaki_source}" >&2
    exit 1
fi

for command in shasum sqlite3 jq; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "Missing required command: ${command}" >&2
        exit 1
    fi
done

catalog_digest_output=$(shasum -a 256 "${catalog_source}")
catalog_source_digest=${catalog_digest_output%% *}
catalog_integrity=$(sqlite3 "${catalog_source}" "PRAGMA integrity_check;")
if [ "${catalog_integrity}" != "ok" ]; then
    echo "Authoritative catalog failed SQLite integrity_check: ${catalog_integrity}" >&2
    exit 1
fi

mkdir -p "${destination}"
staging_directory=$(mktemp -d "${destination}/.prepare-crawl-enrichment.XXXXXX")
cleanup() {
    if [ -n "${staging_directory:-}" ] && [ -d "${staging_directory}" ]; then
        rm -rf "${staging_directory}"
    fi
}
trap cleanup 0
trap 'exit 1' 1 2 3 15

staged_enrichment="${staging_directory}/crawl-c108-shinagaki.json"
cp "${shinagaki_source}" "${staged_enrichment}"
chmod 0644 "${staged_enrichment}"

if [ ! -s "${staged_enrichment}" ]; then
    echo "Crawl enrichment is empty: ${shinagaki_source}" >&2
    exit 1
fi

if ! jq -e --arg catalog_digest "${catalog_source_digest}" '
    def is_integer: type == "number" and . == floor;

    type == "array" and length > 0 and
    all(.[];
        (.tweet_id | type == "string" and length > 0) and
        (
            (
                .post_confidence == "high" and
                .placement_confidence == "high" and
                (.media | type == "array" and length > 0) and
                (.matched_circles | type == "array" and length > 0) and
                ([.matched_circles[].score] | min) == ([.matched_circles[].score] | max)
            ) or
            (
                .post_confidence == "low" and
                ((.attendance.status // "unknown") != "unknown") and
                ((.attendance.confidence // "unmatched") | IN("high", "medium"))
            )
        ) and
        any(.provenance[]?;
            (.sourceId | type == "string" and length > 0) and
            (.sourceKind | type == "string" and length > 0) and
            ((.payloadSha256 // "") | test("^[0-9a-f]{64}$")) and
            ((.observationKey // "") | test("^[0-9a-f]{64}$"))
        ) and
        (.matched_circles | type == "array") and
        all(.matched_circles[];
            . as $circle |
            ($circle.comiket_no | is_integer and . == 108) and
            ($circle.circle_id | is_integer) and
            ($circle.wc_id | is_integer) and
            any($circle.provenance[]?;
                .sourceId == "circlems_webcatalog" and
                .payloadSha256 == $catalog_digest and
                (.recordId |
                    type == "string" and
                    (
                        . == ("108:" + ($circle.circle_id | tostring)) or
                        startswith("108:" + ($circle.circle_id | tostring) + ":")
                    )
                ) and
                (.fields | type == "array" and length > 0)
            )
        )
    )
' "${staged_enrichment}" >/dev/null; then
    echo "Crawl enrichment is missing publishable confidence, complete post, or authoritative Circle.ms provenance." >&2
    exit 1
fi

duplicate_wcid_ownership_count=$(
    sqlite3 -bail "${catalog_source}" '
        SELECT COUNT(*)
        FROM (
            SELECT comiketNo, WCId
            FROM ComiketCircleExtend
            GROUP BY comiketNo, WCId
            HAVING COUNT(*) > 1
        );
    '
)
if [ "${duplicate_wcid_ownership_count}" -ne 0 ]; then
    echo "Authoritative catalog contains ${duplicate_wcid_ownership_count} duplicate (comiketNo, WCId) ownership pair(s)." >&2
    exit 1
fi

expected_circles="${staging_directory}/expected-circles.tsv"
jq -r '.[] | .matched_circles[] | [.comiket_no, .circle_id, .wc_id] | @tsv' \
    "${staged_enrichment}" >"${expected_circles}"
if [ ! -s "${expected_circles}" ]; then
    echo "Crawl enrichment did not contain any matched Circle.ms circles." >&2
    exit 1
fi

unresolved_circle_count=$(
    sqlite3 -bail "${catalog_source}" <<SQL
CREATE TEMP TABLE expected_circles (
    comiket_no INTEGER NOT NULL,
    circle_id INTEGER NOT NULL,
    wc_id INTEGER NOT NULL
);
.mode tabs
.import "${expected_circles}" expected_circles
SELECT COUNT(*)
FROM expected_circles AS expected
WHERE (
    SELECT COUNT(*)
    FROM ComiketCircleExtend AS circle
    WHERE circle.comiketNo = expected.comiket_no
      AND circle.id = expected.circle_id
      AND circle.WCId = expected.wc_id
) != 1;
SQL
)
if [ "${unresolved_circle_count}" -ne 0 ]; then
    echo "Crawl enrichment contains ${unresolved_circle_count} matched circle(s) without exactly one authoritative ComiketCircleExtend row matching comiket_no, circle_id, and wc_id." >&2
    exit 1
fi

mv -f "${staged_enrichment}" "${destination}/crawl-c108-shinagaki.json"
rm -f "${expected_circles}"
rmdir "${staging_directory}"
staging_directory=
echo "Prepared C108 crawl enrichment in ${destination}"
