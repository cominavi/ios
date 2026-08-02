#!/bin/sh

set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_directory=$(CDPATH= cd -- "${script_directory}/.." && pwd)
collector_directory=${1:-"${project_directory}/../collector"}
shinagaki_input=${2:-"${collector_directory}/out/c108-enriched/selected-posts.json"}
destination="${project_directory}/ComiNavi/Resources/CrawlCatalogs/C108"
catalog_library="${project_directory}/ComiNavi/DataSource/Circlems/CatalogLibrary.swift"

catalog_source="${collector_directory}/out/catalog-seed/webcatalog108.db"
if [ -d "${shinagaki_input}" ]; then
    shinagaki_source="${shinagaki_input}/selected-posts.json"
else
    shinagaki_source="${shinagaki_input}"
fi

if [ ! -f "${catalog_source}" ]; then
    echo "Missing crawl catalog: ${catalog_source}" >&2
    exit 1
fi

if [ ! -f "${shinagaki_source}" ]; then
    echo "Missing crawl enrichment: ${shinagaki_source}" >&2
    exit 1
fi

if [ ! -f "${catalog_library}" ]; then
    echo "Missing catalog configuration: ${catalog_library}" >&2
    exit 1
fi

if ! command -v shasum >/dev/null 2>&1; then
    echo "Missing required command: shasum" >&2
    exit 1
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "Missing required command: sqlite3" >&2
    exit 1
fi

expected_catalog_digest=$(
    awk '
        /^struct CrawlCatalogSource:/ {
            in_crawl_source = 1
        }
        in_crawl_source && /main: \.init\(/ {
            in_main_database = 1
        }
        in_crawl_source && in_main_database && /digest: "/ {
            digest = $0
            sub(/^.*digest: "/, "", digest)
            sub(/".*$/, "", digest)
            if (length(digest) == 64 && digest ~ /^[[:xdigit:]]+$/) {
                print tolower(digest)
            }
            exit
        }
    ' "${catalog_library}"
)

if [ -z "${expected_catalog_digest}" ]; then
    echo "Could not read the C108 main database SHA-256 from ${catalog_library}" >&2
    exit 1
fi

catalog_digest_output=$(shasum -a 256 "${catalog_source}")
catalog_source_digest=${catalog_digest_output%% *}
if [ "${catalog_source_digest}" != "${expected_catalog_digest}" ]; then
    {
        echo "Crawl catalog SHA-256 does not match CatalogLibrary.swift."
        echo "Source:   ${catalog_source}"
        echo "Computed: ${catalog_source_digest}"
        echo "Expected: ${expected_catalog_digest}"
        echo "Update the crawl source or intentionally update CrawlCatalogSource before copying."
    } >&2
    exit 1
fi

mkdir -p "${destination}"
staging_directory=$(mktemp -d "${destination}/.prepare-crawl-catalog.XXXXXX")
cleanup() {
    if [ -n "${staging_directory:-}" ] && [ -d "${staging_directory}" ]; then
        rm -rf "${staging_directory}"
    fi
}
trap cleanup 0
trap 'exit 1' 1 2 3 15

staged_catalog="${staging_directory}/crawl-c108-main.sqlite"
staged_enrichment="${staging_directory}/crawl-c108-shinagaki.json"
staged_image_database="${staging_directory}/crawl-c108-images.sqlite"

cp "${catalog_source}" "${staged_catalog}"
cp "${shinagaki_source}" "${staged_enrichment}"

sqlite3 "${staged_image_database}" <<'SQL'
CREATE TABLE ComiketCircleImage (
  comiketNo INTEGER NOT NULL,
  id INTEGER NOT NULL,
  WCId INTEGER NOT NULL,
  width INTEGER NOT NULL,
  height INTEGER NOT NULL,
  type VARCHAR(10) NOT NULL,
  size INTEGER NOT NULL,
  md5 VARCHAR(20) NOT NULL,
  cutImage BLOB,
  PRIMARY KEY (comiketNo, id)
);
CREATE TABLE ComiketCommonImage (
  comiketNo INTEGER NOT NULL,
  name VARCHAR(30) NOT NULL,
  width INTEGER NOT NULL,
  height INTEGER NOT NULL,
  type VARCHAR(10) NOT NULL,
  size INTEGER NOT NULL,
  md5 VARCHAR(20) NOT NULL,
  image BLOB,
  PRIMARY KEY (comiketNo, name)
);
SQL

if [ ! -s "${staged_enrichment}" ]; then
    echo "Crawl enrichment is empty: ${shinagaki_source}" >&2
    exit 1
fi

staged_catalog_digest_output=$(shasum -a 256 "${staged_catalog}")
staged_catalog_digest=${staged_catalog_digest_output%% *}
if [ "${staged_catalog_digest}" != "${expected_catalog_digest}" ]; then
    echo "Staged crawl catalog failed SHA-256 verification." >&2
    exit 1
fi

catalog_integrity=$(sqlite3 "${staged_catalog}" "PRAGMA integrity_check;")
if [ "${catalog_integrity}" != "ok" ]; then
    echo "Crawl catalog failed SQLite integrity_check: ${catalog_integrity}" >&2
    exit 1
fi

image_integrity=$(sqlite3 "${staged_image_database}" "PRAGMA integrity_check;")
if [ "${image_integrity}" != "ok" ]; then
    echo "Crawl image database failed SQLite integrity_check: ${image_integrity}" >&2
    exit 1
fi

mv -f "${staged_catalog}" "${destination}/crawl-c108-main.sqlite"
mv -f "${staged_enrichment}" "${destination}/crawl-c108-shinagaki.json"
mv -f "${staged_image_database}" "${destination}/crawl-c108-images.sqlite"

rmdir "${staging_directory}"
staging_directory=
echo "Prepared C108 crawl catalog in ${destination}"
