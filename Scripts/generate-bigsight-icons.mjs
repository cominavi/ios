#!/usr/bin/env node

import { writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const assetRoot = join(repositoryRoot, "ComiNavi", "Assets.xcassets");
const iconifyCollection = "material-symbols";

// Material Symbols Rounded is distributed by Google under Apache 2.0 and
// served through Iconify. Filled symbols remain recognizable at the map's
// smallest marker size, while the rounded family matches the rest of the UI.
const icons = {
  BigSightAccessibleFacilities: {
    file: "accessible-facilities.svg",
    icon: "accessible-rounded",
  },
  BigSightAED: {
    file: "aed.svg",
    icon: "ecg-heart",
  },
  BigSightBabyCareRoom: {
    file: "baby-care-room.svg",
    icon: "baby-changing-station-rounded",
  },
  BigSightBus: {
    file: "bus.svg",
    icon: "directions-bus-rounded",
  },
  BigSightCoinLockers: {
    file: "coin-lockers.svg",
    icon: "luggage-rounded",
  },
  BigSightConferenceTower: {
    file: "conference-tower.svg",
    icon: "corporate-fare-rounded",
  },
  BigSightConvenienceStore: {
    file: "convenience-store.svg",
    icon: "local-convenience-store-rounded",
  },
  BigSightCosplayArea: {
    file: "cosplay-area.svg",
    icon: "theater-comedy-rounded",
  },
  BigSightCosplayChanging: {
    file: "cosplay-changing.svg",
    icon: "checkroom-rounded",
  },
  BigSightClosedArea: {
    file: "closed-area.svg",
    icon: "block",
  },
  // Venue identifiers are rendered in app code as original bilingual badges.
  BigSightElevator: {
    file: "elevator.svg",
    icon: "elevator-rounded",
  },
  BigSightEntryGate: {
    file: "entry-gate.svg",
    icon: "door-open-rounded",
  },
  BigSightEscalator: {
    file: "escalator.svg",
    icon: "escalator",
  },
  BigSightFirstAidRoom: {
    file: "first-aid-room.svg",
    icon: "medical-services-rounded",
  },
  BigSightFood: {
    file: "food.svg",
    icon: "restaurant-rounded",
  },
  BigSightInfantFacilities: {
    file: "infant-facilities.svg",
    icon: "stroller-rounded",
  },
  BigSightInformation: {
    file: "information.svg",
    icon: "info-rounded",
  },
  BigSightNursingRoom: {
    file: "nursing-room.svg",
    icon: "breastfeeding",
  },
  BigSightOstomateRestroom: {
    file: "ostomate-restroom.svg",
    icon: "accessible-forward-rounded",
  },
  BigSightParking: {
    file: "parking.svg",
    icon: "local-parking-rounded",
  },
  BigSightPharmacy: {
    file: "pharmacy.svg",
    icon: "local-pharmacy-rounded",
  },
  BigSightPostBox: {
    file: "post-box.svg",
    icon: "markunread-mailbox-rounded",
  },
  BigSightPrayerRoom: {
    file: "prayer-room.svg",
    icon: "folded-hands-rounded",
  },
  BigSightRestroom: {
    file: "restroom.svg",
    icon: "wc-rounded",
  },
  BigSightSmokingArea: {
    file: "smoking-area.svg",
    icon: "smoking-rooms-rounded",
  },
  BigSightStairs: {
    file: "stairs.svg",
    icon: "stairs-rounded",
  },
  BigSightTaxi: {
    file: "taxi.svg",
    icon: "local-taxi-rounded",
  },
  BigSightTicketExchange: {
    file: "ticket-exchange.svg",
    icon: "confirmation-number-rounded",
  },
  BigSightTrain: {
    file: "train.svg",
    icon: "train-rounded",
  },
  BigSightATM: {
    file: "atm.svg",
    icon: "local-atm-rounded",
  },
  BigSightWaitingArea: {
    file: "waiting-area.svg",
    icon: "groups-rounded",
  },
  BigSightWaterBus: {
    file: "water-bus.svg",
    icon: "directions-boat-rounded",
  },
  BigSightWorkspace: {
    file: "workspace.svg",
    icon: "desk-rounded",
  },
};

const iconNames = [...new Set(Object.values(icons).map(({ icon }) => icon))];
const endpoint = new URL(`https://api.iconify.design/${iconifyCollection}.json`);
endpoint.searchParams.set("icons", iconNames.join(","));

const response = await fetch(endpoint);
if (!response.ok) {
  throw new Error(
    `Iconify request failed: ${response.status} ${response.statusText}`,
  );
}

const collection = await response.json();
const missingIcons = iconNames.filter((name) => collection.icons[name] == null);
if (missingIcons.length > 0) {
  throw new Error(`Iconify did not return: ${missingIcons.join(", ")}`);
}

const svg = (iconName) => {
  const icon = collection.icons[iconName];
  const width = icon.width ?? collection.width ?? 24;
  const height = icon.height ?? collection.height ?? 24;
  const body = icon.body.replaceAll("currentColor", "#221815");

  return `<?xml version="1.0" encoding="UTF-8"?>
<!-- Iconify ${iconifyCollection}:${iconName}; Google Material Symbols, Apache 2.0. -->
<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">
  ${body}
</svg>
`;
};

await Promise.all(
  Object.entries(icons).map(async ([assetName, icon]) => {
    const destination = join(assetRoot, `${assetName}.imageset`, icon.file);
    await writeFile(destination, svg(icon.icon));
  }),
);

console.log(
  `Generated ${Object.keys(icons).length} Big Sight icons from Iconify.`,
);
