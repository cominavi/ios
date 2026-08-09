#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";

const iconSetPath = process.argv[2];
if (!iconSetPath) {
  console.error("Usage: Scripts/generate-lucide-assets.mjs /path/to/@iconify-json/lucide/icons.json");
  process.exit(1);
}

const iconSet = JSON.parse(fs.readFileSync(iconSetPath, "utf8"));
const outputRoot = path.resolve("ComiNavi/Assets.xcassets");
const iconNames = [
  "arrow-down",
  "arrow-down-right",
  "arrow-left-right",
  "at-sign",
  "briefcase-medical",
  "building-2",
  "calendar-clock",
  "calendar-days",
  "check",
  "chevron-down",
  "chevron-right",
  "chevron-up",
  "chevrons-up-down",
  "circle",
  "circle-alert",
  "circle-check-big",
  "circle-arrow-down",
  "info",
  "circle-user",
  "compass",
  "copy",
  "database",
  "delete",
  "drama",
  "door-open",
  "ellipsis",
  "external-link",
  "eye",
  "eye-off",
  "file-text",
  "filter",
  "footprints",
  "git-branch",
  "globe",
  "grid-2x2",
  "image-off",
  "images",
  "layers-3",
  "list-filter",
  "list",
  "loader-circle",
  "locate-fixed",
  "map",
  "map-pin",
  "map-pin-off",
  "maximize-2",
  "minus",
  "move-vertical",
  "mouse-pointer-click",
  "navigation",
  "person-standing",
  "paintbrush",
  "plus",
  "radio-tower",
  "refresh-cw",
  "rotate-cw",
  "ruler",
  "scan-search",
  "scan-text",
  "search",
  "settings",
  "share",
  "shopping-cart",
  "sliders-horizontal",
  "star",
  "sparkles",
  "tag",
  "tag-x",
  "triangle-alert",
  "user-round-minus",
  "user-round-plus",
  "user-round-x",
  "users",
  "wifi-off",
  "x",
];

for (const name of iconNames) {
  const icon = iconSet.icons[name];
  if (!icon) {
    throw new Error(`Lucide icon is missing from Iconify: ${name}`);
  }

  const width = icon.width ?? iconSet.width ?? 24;
  const height = icon.height ?? iconSet.height ?? 24;
  const body = icon.body.replaceAll("currentColor", "#000000");
  const svg = [
    `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">`,
    body,
    "</svg>",
    "",
  ].join("\n");
  const assetName = `lucide-${name}`;
  const imageset = path.join(outputRoot, `${assetName}.imageset`);
  fs.mkdirSync(imageset, { recursive: true });
  fs.writeFileSync(path.join(imageset, `${assetName}.svg`), svg);
  fs.writeFileSync(
    path.join(imageset, "Contents.json"),
    `${JSON.stringify(
      {
        images: [
          {
            filename: `${assetName}.svg`,
            idiom: "universal",
          },
        ],
        info: { author: "xcode", version: 1 },
        properties: {
          "preserves-vector-representation": true,
          "template-rendering-intent": "template",
        },
      },
      null,
      2,
    )}\n`,
  );
}

console.log(`Generated ${iconNames.length} Lucide assets from Iconify.`);
