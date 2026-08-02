#!/bin/zsh

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /path/to/bigsight-map-icons-svg" >&2
  exit 64
fi

script_dir=${0:A:h}
project_dir=${script_dir:h}
source_dir=${1:A}
catalog_dir="$project_dir/ComiNavi/Assets.xcassets"
template="$script_dir/BigSightMapIconContents.json"

icons=(
  accessible-facilities:BigSightAccessibleFacilities
  aed:BigSightAED
  baby-care-room:BigSightBabyCareRoom
  bus:BigSightBus
  coin-lockers:BigSightCoinLockers
  conference-tower:BigSightConferenceTower
  elevator:BigSightElevator
  escalator:BigSightEscalator
  first-aid-room:BigSightFirstAidRoom
  infant-facilities:BigSightInfantFacilities
  information:BigSightInformation
  nursing-room:BigSightNursingRoom
  ostomate-restroom:BigSightOstomateRestroom
  parking:BigSightParking
  post-box:BigSightPostBox
  prayer-room:BigSightPrayerRoom
  restroom:BigSightRestroom
  smoking-area:BigSightSmokingArea
  taxi:BigSightTaxi
  train:BigSightTrain
  water-bus:BigSightWaterBus
  workspace:BigSightWorkspace
)

# East, West, and South are intentionally excluded. The app renders original
# bilingual venue badges instead of importing the guide's artwork.

for mapping in $icons; do
  source_name=${mapping%%:*}
  asset_name=${mapping##*:}
  source_file="$source_dir/$source_name.svg"
  imageset="$catalog_dir/$asset_name.imageset"

  if [[ ! -f "$source_file" ]]; then
    echo "Missing source icon: $source_file" >&2
    exit 66
  fi

  mkdir -p "$imageset"
  cp "$source_file" "$imageset/$source_name.svg"
  sed "s/__FILENAME__/$source_name.svg/" "$template" > "$imageset/Contents.json"
done

echo "Imported ${#icons} vector map icons into $catalog_dir"
