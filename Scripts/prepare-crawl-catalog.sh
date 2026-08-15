#!/bin/sh

set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_directory=$(CDPATH= cd -- "${script_directory}/.." && pwd)
collector_directory=${1:-"${project_directory}/../collector"}
shinagaki_input=${2:-"${collector_directory}/out/c108-enriched/selected-posts.json"}
destination="${project_directory}/ComiNavi/Resources/CrawlCatalogs/C108"
catalog_source="${collector_directory}/out/catalog-seed/webcatalog108.db"
matching_policy_source="${collector_directory}/src/matcher.rs"

if [ -d "${shinagaki_input}" ]; then
    shinagaki_source="${shinagaki_input}/selected-posts.json"
else
    shinagaki_source="${shinagaki_input}"
fi
ocr_source=${3:-"$(dirname -- "${shinagaki_source}")/enrichment.json"}

if [ ! -f "${catalog_source}" ]; then
    echo "Missing authoritative catalog used to validate crawl enrichment: ${catalog_source}" >&2
    exit 1
fi

if [ ! -f "${shinagaki_source}" ]; then
    echo "Missing crawl enrichment: ${shinagaki_source}" >&2
    exit 1
fi

if [ ! -f "${ocr_source}" ]; then
    echo "Missing OCR enrichment archive: ${ocr_source}" >&2
    exit 1
fi

if [ ! -f "${matching_policy_source}" ]; then
    echo "Missing collector matching-policy source: ${matching_policy_source}" >&2
    exit 1
fi

expected_matching_policy_id=$(sed -n 's/^pub const MATCHING_POLICY_ID: &str = "\([^"]*\)";$/\1/p' "${matching_policy_source}")
if [ -z "${expected_matching_policy_id}" ]; then
    echo "Could not resolve the collector matching policy from: ${matching_policy_source}" >&2
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
staged_ocr_search="${staging_directory}/crawl-c108-ocr-search.json"
cp "${shinagaki_source}" "${staged_enrichment}"
jq -c --slurpfile selected "${shinagaki_source}" '
    ($selected[0] | INDEX(.tweet_id)) as $selected_post_ids |
    {
        schema_version: 1,
        minimum_confidence: 0.80,
        posts: (
            reduce .posts[] as $post ({};
                (
                    $post.ocr // [] |
                    [
                        .[].lines[]? |
                        select(
                            (.confidence | type == "number") and
                            .confidence >= 0.80 and
                            (.rawText | type == "string" and length > 0)
                        ) |
                        .rawText
                    ] |
                    unique |
                    join("\n")
                ) as $text |
                if $selected_post_ids[$post.tweetId] != null and ($text | length) > 0 then
                    .[$post.tweetId] = $text
                else
                    .
                end
            )
        )
    }
' "${ocr_source}" >"${staged_ocr_search}"
chmod 0644 "${staged_enrichment}"
chmod 0644 "${staged_ocr_search}"

if [ ! -s "${staged_enrichment}" ]; then
    echo "Crawl enrichment is empty: ${shinagaki_source}" >&2
    exit 1
fi

if ! jq -e \
    --arg catalog_digest "${catalog_source_digest}" \
    --arg matching_policy_id "${expected_matching_policy_id}" '
    def is_integer: type == "number" and . == floor;
    def reportable_attendance:
        ((.attendance.status // "unknown") != "unknown") and
        ((.attendance.confidence // "unmatched") | IN("high", "medium"));
    def valid_circle($catalog_digest):
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
        );

    type == "array" and length > 0 and
    all(.[];
        (.tweet_id | type == "string" and length > 0) and
        (.matching_policy_id == $matching_policy_id) and
        (
            .providerRelationships as $relationships |
            ($relationships | type == "object") and
            $relationships.decision == "eligible" and
            $relationships.metadataComplete == true and
            (($relationships | has("retweetedPostId")) | not) and
            (
                if (($relationships | has("quotedPostId")) or
                    ($relationships | has("quotedAuthorId"))) then
                    ($relationships.quotedPostId | type == "string" and length > 0) and
                    ($relationships.quotedAuthorId | type == "string" and length > 0) and
                    ($relationships.authorId | type == "string" and length > 0) and
                    $relationships.authorId == $relationships.quotedAuthorId
                else
                    (($relationships | has("quotedPostId")) | not) and
                    (($relationships | has("quotedAuthorId")) | not)
                end
            )
        ) and
        (
            [.post_reasons[]?] |
            all(.[];
                . != "native_retweet" and
                . != "cross_author_quote" and
                . != "unverifiable_quote_author"
            )
        ) and
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
                reportable_attendance and
                (.matched_circles | type == "array" and length == 0)
            )
        ) and
        any(.provenance[]?;
            (.sourceId | type == "string" and length > 0) and
            (.sourceKind | type == "string" and length > 0) and
            ((.payloadSha256 // "") | test("^[0-9a-f]{64}$")) and
            ((.observationKey // "") | test("^[0-9a-f]{64}$"))
        ) and
        (.matched_circles | type == "array") and
        all(.matched_circles[]; valid_circle($catalog_digest)) and
        (.attendance_targets | type == "array") and
        (
            if reportable_attendance then
                (.attendance_targets | length > 0)
            else
                (.attendance_targets | length == 0)
            end
        ) and
        all(.attendance_targets[]; valid_circle($catalog_digest))
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
jq -r '.[] | (.matched_circles + .attendance_targets)[] | [.comiket_no, .circle_id, .wc_id] | @tsv' \
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
mv -f "${staged_ocr_search}" "${destination}/crawl-c108-ocr-search.json"
rm -f "${expected_circles}"
rmdir "${staging_directory}"
staging_directory=
echo "Prepared C108 crawl enrichment in ${destination}"
