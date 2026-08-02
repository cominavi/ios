#!/bin/zsh

set -euo pipefail

if (( $# > 2 )); then
  print -u2 "usage: $0 [production-data-directory] [destination-directory]"
  exit 64
fi

script_directory=${0:A:h}
project_directory=${script_directory:h}
source_directory=${1:-"/Volumes/Backup of MacBook Pro/Users/galvingao/Projects/ComiNavi/productiondata"}
destination_directory=${2:-"${project_directory}/ComiNavi/Resources/DemoCatalogs/C104"}

main_source="${source_directory}/webcatalog104.db"
image_source="${source_directory}/webcatalog104Image1.db"
main_destination="${destination_directory}/demo-c104-main.sqlite"
image_destination="${destination_directory}/demo-c104-images.sqlite"

for source_file in "${main_source}" "${image_source}"; do
  if [[ ! -r "${source_file}" ]]; then
    print -u2 "missing readable production catalog: ${source_file}"
    exit 66
  fi
done

if [[ "${image_source}" == *"'"* ]]; then
  print -u2 "the production data path cannot contain an apostrophe"
  exit 65
fi

mkdir -p "${destination_directory}"

main_temporary="${main_destination}.preparing"
image_temporary="${image_destination}.preparing"
rm -f "${main_temporary}" "${image_temporary}"

cp "${main_source}" "${main_temporary}"
sqlite3 "${main_temporary}" <<'SQL'
PRAGMA journal_mode = DELETE;
PRAGMA quick_check;
VACUUM;
SQL

sqlite3 "${image_temporary}" <<SQL
ATTACH DATABASE '${image_source}' AS production;
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
INSERT INTO ComiketCommonImage SELECT * FROM production.ComiketCommonImage;
INSERT INTO ComiketCircleImage
SELECT * FROM production.ComiketCircleImage;
DETACH DATABASE production;
PRAGMA journal_mode = DELETE;
VACUUM;
PRAGMA quick_check;
SQL

mv "${main_temporary}" "${main_destination}"
mv "${image_temporary}" "${image_destination}"

print "Prepared C104 demo catalog:"
du -h "${main_destination}" "${image_destination}"
shasum -a 256 "${main_destination}" "${image_destination}"
