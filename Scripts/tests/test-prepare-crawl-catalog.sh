#!/bin/sh

set -eu

test_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
script_under_test="${test_directory}/../prepare-crawl-catalog.sh"
fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/prepare-crawl-catalog-tests.XXXXXX")
fixture_hash=0000000000000000000000000000000000000000000000000000000000000000
wrong_catalog_digest=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
current_matching_policy_id=c108-shinagaki-placement-v5

cleanup() {
    if [ -n "${fixture_root:-}" ] && [ -d "${fixture_root}" ]; then
        rm -rf "${fixture_root}"
    fi
}
trap cleanup 0
trap 'exit 1' 1 2 3 15

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

prepare_case() {
    case_name=$1
    case_circle=$2
    case_catalog_rows=$3
    case_digest_mode=${4:-catalog}
    case_record_id=${5:-108:10}
    case_root="${fixture_root}/${case_name}"
    case_project="${case_root}/ios"
    case_collector="${case_root}/collector"
    case_enrichment="${case_collector}/out/c108-enriched/selected-posts.json"
    case_ocr="${case_collector}/out/c108-enriched/enrichment.json"
    case_catalog="${case_collector}/out/catalog-seed/webcatalog108.db"
    case_destination="${case_project}/ComiNavi/Resources/CrawlCatalogs/C108"
    case_stdout="${case_root}/stdout.txt"
    case_stderr="${case_root}/stderr.txt"

    mkdir -p \
        "${case_project}/Scripts" \
        "${case_collector}/src" \
        "${case_collector}/out/c108-enriched" \
        "${case_collector}/out/catalog-seed"
    cp "${script_under_test}" "${case_project}/Scripts/prepare-crawl-catalog.sh"
    chmod +x "${case_project}/Scripts/prepare-crawl-catalog.sh"
    printf 'pub const MATCHING_POLICY_ID: &str = "%s";\n' \
        "${current_matching_policy_id}" >"${case_collector}/src/matcher.rs"

    sqlite3 "${case_catalog}" <<SQL
CREATE TABLE ComiketCircleExtend (
    comiketNo INTEGER NOT NULL,
    id INTEGER NOT NULL,
    WCId INTEGER NOT NULL
);
${case_catalog_rows}
SQL

    case_catalog_digest_output=$(shasum -a 256 "${case_catalog}")
    case_catalog_digest=${case_catalog_digest_output%% *}

    case "${case_digest_mode}" in
        catalog)
            case_provenance_digest=${case_catalog_digest}
            ;;
        wrong)
            case_provenance_digest=${wrong_catalog_digest}
            ;;
        *)
            fail "Unknown provenance digest mode: ${case_digest_mode}"
            ;;
    esac

    jq -n \
        --arg hash "${fixture_hash}" \
        --arg catalog_digest "${case_provenance_digest}" \
        --arg matching_policy_id "${current_matching_policy_id}" \
        --arg record_id "${case_record_id}" \
        --argjson circle "${case_circle}" '
        [
            {
                tweet_id: "test-post",
                post_confidence: "high",
                placement_confidence: "high",
                matching_policy_id: $matching_policy_id,
                providerRelationships: {
                    decision: "eligible",
                    metadataComplete: true
                },
                media: [{kind: "photo", url: "https://example.test/menu.jpg"}],
                provenance: [
                    {
                        sourceId: "test-post-source",
                        sourceKind: "test_fixture",
                        payloadSha256: $hash,
                        observationKey: $hash
                    }
                ],
                matched_circles: [
                    ($circle + {
                        score: 100,
                        provenance: [
                            {
                                sourceId: "circlems_webcatalog",
                                sourceKind: "catalog_snapshot",
                                recordId: $record_id,
                                payloadSha256: $catalog_digest,
                                fields: ["WCId"]
                            }
                        ]
                    })
                ],
                attendance_targets: []
            }
        ]
    ' >"${case_enrichment}"

    jq -n '
        {
            schemaVersion: 1,
            posts: [
                {
                    tweetId: "test-post",
                    ocr: [
                        {
                            lines: [
                                {rawText: "高信頼OCRテキスト", confidence: 0.93},
                                {rawText: "低信頼OCRテキスト", confidence: 0.79}
                            ]
                        }
                    ]
                }
            ]
        }
    ' >"${case_ocr}"
}

run_success_case() {
    prepare_case "$1" "$2" "$3" "${4:-catalog}" "${5:-108:10}"

    if ! "${case_project}/Scripts/prepare-crawl-catalog.sh" \
        "${case_collector}" \
        "${case_enrichment}" \
        >"${case_stdout}" 2>"${case_stderr}"; then
        sed -n '1,120p' "${case_stderr}" >&2
        fail "$1 should have passed"
    fi

    if [ ! -f "${case_destination}/crawl-c108-shinagaki.json" ]; then
        fail "$1 did not stage crawl-c108-shinagaki.json"
    fi
    if ! cmp -s "${case_enrichment}" \
        "${case_destination}/crawl-c108-shinagaki.json"; then
        fail "$1 rewrote the validated Shinagaki catalog"
    fi
    if ! jq -e '
        .schema_version == 1 and
        .minimum_confidence == 0.8 and
        .posts["test-post"] == "高信頼OCRテキスト" and
        (.posts["test-post"] | contains("低信頼OCRテキスト") | not)
    ' "${case_destination}/crawl-c108-ocr-search.json" >/dev/null; then
        fail "$1 did not publish only high-confidence OCR search text"
    fi
    echo "PASS: $1"
}

run_failure_case() {
    expected_error=$4
    prepare_case "$1" "$2" "$3" "${5:-catalog}" "${6:-108:10}"

    if "${case_project}/Scripts/prepare-crawl-catalog.sh" \
        "${case_collector}" \
        "${case_enrichment}" \
        >"${case_stdout}" 2>"${case_stderr}"; then
        fail "$1 should have failed closed"
    fi

    if ! grep -F "${expected_error}" "${case_stderr}" >/dev/null; then
        sed -n '1,120p' "${case_stderr}" >&2
        fail "$1 emitted the wrong validation error"
    fi

    if [ -e "${case_destination}/crawl-c108-shinagaki.json" ]; then
        fail "$1 published crawl-c108-shinagaki.json after validation failed"
    fi
    if [ -e "${case_destination}/crawl-c108-ocr-search.json" ]; then
        fail "$1 published crawl-c108-ocr-search.json after validation failed"
    fi
    echo "PASS: $1"
}

run_confidence_failure_case() {
    prepare_case "$1" "${valid_circle}" "${valid_row}"
    jq '.[0].post_confidence = "medium"' "${case_enrichment}" >"${case_enrichment}.tmp"
    mv "${case_enrichment}.tmp" "${case_enrichment}"

    if "${case_project}/Scripts/prepare-crawl-catalog.sh" \
        "${case_collector}" \
        "${case_enrichment}" \
        >"${case_stdout}" 2>"${case_stderr}"; then
        fail "$1 should have rejected a non-high Shinagaki match"
    fi

    if ! grep -F "${schema_error}" "${case_stderr}" >/dev/null; then
        sed -n '1,120p' "${case_stderr}" >&2
        fail "$1 emitted the wrong validation error"
    fi
    echo "PASS: $1"
}

run_relationship_failure_case() {
    prepare_case "$1" "${valid_circle}" "${valid_row}"
    jq '.[0].post_reasons = [$reason]' --arg reason "$2" \
        "${case_enrichment}" >"${case_enrichment}.tmp"
    mv "${case_enrichment}.tmp" "${case_enrichment}"

    if "${case_project}/Scripts/prepare-crawl-catalog.sh" \
        "${case_collector}" \
        "${case_enrichment}" \
        >"${case_stdout}" 2>"${case_stderr}"; then
        fail "$1 should have rejected relationship-derived media"
    fi

    if ! grep -F "${schema_error}" "${case_stderr}" >/dev/null; then
        sed -n '1,120p' "${case_stderr}" >&2
        fail "$1 emitted the wrong validation error"
    fi
    echo "PASS: $1"
}

run_relationship_metadata_failure_case() {
    prepare_case "$1" "${valid_circle}" "${valid_row}"
    jq "$2" "${case_enrichment}" >"${case_enrichment}.tmp"
    mv "${case_enrichment}.tmp" "${case_enrichment}"

    if "${case_project}/Scripts/prepare-crawl-catalog.sh" \
        "${case_collector}" \
        "${case_enrichment}" \
        >"${case_stdout}" 2>"${case_stderr}"; then
        fail "$1 should have rejected incomplete provider relationship metadata"
    fi

    if ! grep -F "${schema_error}" "${case_stderr}" >/dev/null; then
        sed -n '1,120p' "${case_stderr}" >&2
        fail "$1 emitted the wrong validation error"
    fi
    echo "PASS: $1"
}

run_same_author_quote_success_case() {
    prepare_case "$1" "${valid_circle}" "${valid_row}"
    jq '.[0].providerRelationships += {
        quotedPostId: "quoted-post",
        quotedAuthorId: "source-author",
        authorId: "source-author"
    }' "${case_enrichment}" >"${case_enrichment}.tmp"
    mv "${case_enrichment}.tmp" "${case_enrichment}"

    if ! "${case_project}/Scripts/prepare-crawl-catalog.sh" \
        "${case_collector}" \
        "${case_enrichment}" \
        >"${case_stdout}" 2>"${case_stderr}"; then
        sed -n '1,120p' "${case_stderr}" >&2
        fail "$1 should have accepted a same-author quote"
    fi
    echo "PASS: $1"
}

run_attendance_success_case() {
    case_name=$1
    second_circle='{"comiket_no":108,"circle_id":11,"wc_id":1001}'
    attendance_rows='INSERT INTO ComiketCircleExtend (comiketNo, id, WCId) VALUES (108, 10, 1000); INSERT INTO ComiketCircleExtend (comiketNo, id, WCId) VALUES (108, 11, 1001);'
    prepare_case "${case_name}" "${valid_circle}" "${attendance_rows}"
    jq \
        --arg catalog_digest "${case_catalog_digest}" \
        --argjson second_circle "${second_circle}" '
        .[0].matched_circles[0] as $first_target |
        .[0] |= (
            .tweet_id = "2083911737565450341" |
            .post_confidence = "low" |
            .placement_confidence = "unmatched" |
            .media = [] |
            .attendance = {
                status: "withdrawn",
                confidence: "high",
                policyId: "operator-withdrawal-label-v1"
            } |
            .attendance_targets = [
                $first_target,
                ($second_circle + {
                    score: 100,
                    provenance: [
                        {
                            sourceId: "circlems_webcatalog",
                            sourceKind: "catalog_snapshot",
                            recordId: "108:11",
                            payloadSha256: $catalog_digest,
                            fields: ["WCId"]
                        }
                    ]
                })
            ] |
            .matched_circles = []
        )
    ' "${case_enrichment}" >"${case_enrichment}.tmp"
    mv "${case_enrichment}.tmp" "${case_enrichment}"

    if ! "${case_project}/Scripts/prepare-crawl-catalog.sh" \
        "${case_collector}" \
        "${case_enrichment}" \
        >"${case_stdout}" 2>"${case_stderr}"; then
        sed -n '1,120p' "${case_stderr}" >&2
        fail "${case_name} should have published reportable attendance"
    fi
    if ! jq -e '
        .[0].tweet_id == "2083911737565450341" and
        (.[0].matched_circles | length == 0) and
        (.[0].attendance_targets | length == 2)
    ' "${case_destination}/crawl-c108-shinagaki.json" >/dev/null; then
        fail "${case_name} did not preserve attendance targets without menu matches"
    fi
    echo "PASS: ${case_name}"
}

run_missing_attendance_targets_failure_case() {
    case_name=$1
    prepare_case "${case_name}" "${valid_circle}" "${valid_row}"
    jq '
        .[0] |= (
            .post_confidence = "low" |
            .placement_confidence = "unmatched" |
            .media = [] |
            .matched_circles = [] |
            .attendance_targets = [] |
            .attendance = {status: "withdrawn", confidence: "high"}
        )
    ' "${case_enrichment}" >"${case_enrichment}.tmp"
    mv "${case_enrichment}.tmp" "${case_enrichment}"

    if "${case_project}/Scripts/prepare-crawl-catalog.sh" \
        "${case_collector}" \
        "${case_enrichment}" \
        >"${case_stdout}" 2>"${case_stderr}"; then
        fail "${case_name} should have rejected reportable attendance without targets"
    fi
    if ! grep -F "${schema_error}" "${case_stderr}" >/dev/null; then
        sed -n '1,120p' "${case_stderr}" >&2
        fail "${case_name} emitted the wrong validation error"
    fi
    echo "PASS: ${case_name}"
}

run_matching_policy_failure_case() {
    case_name=$1
    policy_mode=$2
    prepare_case "${case_name}" "${valid_circle}" "${valid_row}"
    case "${policy_mode}" in
        missing)
            jq 'del(.[0].matching_policy_id)' "${case_enrichment}" >"${case_enrichment}.tmp"
            ;;
        stale)
            jq '.[0].matching_policy_id = "c108-shinagaki-placement-v4"' \
                "${case_enrichment}" >"${case_enrichment}.tmp"
            ;;
        *)
            fail "Unknown matching-policy fixture mode: ${policy_mode}"
            ;;
    esac
    mv "${case_enrichment}.tmp" "${case_enrichment}"

    if "${case_project}/Scripts/prepare-crawl-catalog.sh" \
        "${case_collector}" \
        "${case_enrichment}" \
        >"${case_stdout}" 2>"${case_stderr}"; then
        fail "${case_name} should have rejected ${policy_mode} matching policy"
    fi
    if ! grep -F "${schema_error}" "${case_stderr}" >/dev/null; then
        sed -n '1,120p' "${case_stderr}" >&2
        fail "${case_name} emitted the wrong validation error"
    fi
    echo "PASS: ${case_name}"
}

valid_circle='{"comiket_no":108,"circle_id":10,"wc_id":1000}'
valid_row='INSERT INTO ComiketCircleExtend (comiketNo, id, WCId) VALUES (108, 10, 1000);'
schema_error='Crawl enrichment is missing publishable confidence, complete post, or authoritative Circle.ms provenance.'
ownership_error='duplicate (comiketNo, WCId) ownership pair(s).'
resolution_error='without exactly one authoritative ComiketCircleExtend row matching comiket_no, circle_id, and wc_id.'

run_success_case \
    valid_triple \
    "${valid_circle}" \
    "${valid_row}"
run_success_case \
    valid_prefixed_record_id \
    "${valid_circle}" \
    "${valid_row}" \
    catalog \
    '108:10:ComiketCircleExtend.twitterURL:test'
run_attendance_success_case \
    valid_two_circle_withdrawal
run_missing_attendance_targets_failure_case \
    reportable_attendance_without_targets
run_matching_policy_failure_case \
    missing_matching_policy \
    missing
run_matching_policy_failure_case \
    stale_matching_policy \
    stale
run_confidence_failure_case \
    medium_shinagaki_confidence
run_relationship_failure_case \
    native_retweet \
    native_retweet
run_relationship_failure_case \
    cross_author_quote \
    cross_author_quote
run_relationship_failure_case \
    unverifiable_quote_author \
    unverifiable_quote_author
run_relationship_metadata_failure_case \
    missing_provider_relationships \
    'del(.[0].providerRelationships)'
run_relationship_metadata_failure_case \
    ineligible_provider_relationships \
    '.[0].providerRelationships.decision = "native_retweet"'
run_relationship_metadata_failure_case \
    incomplete_provider_relationships \
    '.[0].providerRelationships.metadataComplete = false'
run_relationship_metadata_failure_case \
    retweeted_post_relationship \
    '.[0].providerRelationships.retweetedPostId = "source-post"'
run_relationship_metadata_failure_case \
    cross_author_quote_relationship \
    '.[0].providerRelationships += {quotedPostId: "quoted-post", quotedAuthorId: "quoted-author", authorId: "source-author"}'
run_relationship_metadata_failure_case \
    partial_quote_relationship \
    '.[0].providerRelationships += {quotedPostId: "quoted-post", authorId: "source-author"}'
run_same_author_quote_success_case \
    same_author_quote_relationship
run_failure_case \
    missing_comiket_number \
    '{"circle_id":10,"wc_id":1000}' \
    "${valid_row}" \
    "${schema_error}"
run_failure_case \
    wrong_comiket_number \
    '{"comiket_no":109,"circle_id":10,"wc_id":1000}' \
    "${valid_row}" \
    "${schema_error}"
run_failure_case \
    fractional_circle_id \
    '{"comiket_no":108,"circle_id":10.5,"wc_id":1000}' \
    "${valid_row}" \
    "${schema_error}"
run_failure_case \
    null_wc_id \
    '{"comiket_no":108,"circle_id":10,"wc_id":null}' \
    "${valid_row}" \
    "${schema_error}"
run_failure_case \
    mismatched_authoritative_tuple \
    '{"comiket_no":108,"circle_id":10,"wc_id":1001}' \
    "${valid_row}" \
    "${resolution_error}"
run_failure_case \
    duplicate_authoritative_tuple \
    "${valid_circle}" \
    "${valid_row} ${valid_row}" \
    "${ownership_error}"
run_failure_case \
    duplicate_wcid_owner \
    "${valid_circle}" \
    "${valid_row} INSERT INTO ComiketCircleExtend (comiketNo, id, WCId) VALUES (108, 11, 1000);" \
    "${ownership_error}"
run_failure_case \
    wrong_catalog_digest \
    "${valid_circle}" \
    "${valid_row}" \
    "${schema_error}" \
    wrong
run_failure_case \
    wrong_circle_record_id \
    "${valid_circle}" \
    "${valid_row}" \
    "${schema_error}" \
    catalog \
    '108:100'

echo 'All prepare-crawl-catalog publication invariant tests passed.'
