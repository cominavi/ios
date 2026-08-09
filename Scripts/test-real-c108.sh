#!/usr/bin/env bash

set -euo pipefail

catalog_dir="${1:-/Users/galvin/projects/cominavi-catalog-data/c108}"
destination="${COMINAVI_TEST_DESTINATION:-platform=iOS Simulator,name=ComiNavi App Store 6.5}"
derived_data="/tmp/cominavi-real-c108-tests"
app_path="${derived_data}/Build/Products/Debug-iphonesimulator/ComiNavi.app"
staged_catalog="${app_path}/RealC108"

for database in webcatalog108.db webcatalog108Image1.db; do
  if [[ ! -f "${catalog_dir}/${database}" ]]; then
    echo "Missing ${catalog_dir}/${database}" >&2
    exit 1
  fi
done

xcodebuild \
  -project ComiNavi.xcodeproj \
  -scheme ComiNavi \
  -configuration Debug \
  -destination "${destination}" \
  -derivedDataPath "${derived_data}" \
  build-for-testing

mkdir -p "${staged_catalog}"
cp "${catalog_dir}/webcatalog108.db" "${staged_catalog}/webcatalog108.db"
cp "${catalog_dir}/webcatalog108Image1.db" "${staged_catalog}/webcatalog108Image1.db"
codesign --force --sign - --timestamp=none "${app_path}"

xcodebuild \
  -project ComiNavi.xcodeproj \
  -scheme ComiNavi \
  -configuration Debug \
  -destination "${destination}" \
  -derivedDataPath "${derived_data}" \
  test-without-building \
  -only-testing:ComiNaviTests/RealC108CatalogIntegrationTests
