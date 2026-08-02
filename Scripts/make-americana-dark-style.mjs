#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";

if (process.argv.length !== 4) {
  console.error("Usage: make-americana-dark-style.mjs input-style.json output-style.json");
  process.exit(64);
}

const inputPath = path.resolve(process.argv[2]);
const outputPath = path.resolve(process.argv[3]);
const style = JSON.parse(fs.readFileSync(inputPath, "utf8"));

const namedColors = new Map([
  ["black", [0, 0, 0]],
  ["white", [255, 255, 255]],
  ["gray", [128, 128, 128]],
  ["grey", [128, 128, 128]],
  ["lightcoral", [240, 128, 128]],
  ["lightslategray", [119, 136, 153]],
  ["maroon", [128, 0, 0]],
  ["slategray", [112, 128, 144]],
]);

function clamp(value, minimum, maximum) {
  return Math.min(maximum, Math.max(minimum, value));
}

function rgbToHsl(red, green, blue) {
  const r = red / 255;
  const g = green / 255;
  const b = blue / 255;
  const maximum = Math.max(r, g, b);
  const minimum = Math.min(r, g, b);
  const lightness = (maximum + minimum) / 2;

  if (maximum === minimum) {
    return [0, 0, lightness * 100];
  }

  const delta = maximum - minimum;
  const saturation = lightness > 0.5
    ? delta / (2 - maximum - minimum)
    : delta / (maximum + minimum);
  let hue;
  if (maximum === r) hue = (g - b) / delta + (g < b ? 6 : 0);
  else if (maximum === g) hue = (b - r) / delta + 2;
  else hue = (r - g) / delta + 4;
  return [hue * 60, saturation * 100, lightness * 100];
}

function parseHex(value) {
  const hex = value.slice(1);
  if (![3, 4, 6, 8].includes(hex.length)) return null;
  const expanded = hex.length <= 4
    ? [...hex].map(character => character + character).join("")
    : hex;
  const alpha = expanded.length === 8 ? parseInt(expanded.slice(6, 8), 16) / 255 : 1;
  return [
    parseInt(expanded.slice(0, 2), 16),
    parseInt(expanded.slice(2, 4), 16),
    parseInt(expanded.slice(4, 6), 16),
    alpha,
  ];
}

function darkLightness(lightness) {
  // Keep adjacent light-map land-use shades separated after moving them into
  // the dark range. A strict inversion crushes every 85-96% surface together.
  return clamp(8 + (100 - lightness) * 0.8, 8, 88);
}

function darkColor(value) {
  let hue;
  let saturation;
  let lightness;
  let alpha = 1;

  let match = value.match(/^hsla?\(\s*(-?[\d.]+)\s*,\s*([\d.]+)%\s*,\s*([\d.]+)%(?:\s*,\s*([\d.]+%?))?\s*\)$/i);
  if (match) {
    hue = Number(match[1]);
    saturation = Number(match[2]);
    lightness = Number(match[3]);
    if (match[4]) alpha = match[4].endsWith("%") ? Number(match[4].slice(0, -1)) / 100 : Number(match[4]);
  } else {
    match = value.match(/^rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)(?:\s*,\s*([\d.]+))?\s*\)$/i);
    let rgba;
    if (match) {
      rgba = [Number(match[1]), Number(match[2]), Number(match[3]), match[4] ? Number(match[4]) : 1];
    } else if (value.startsWith("#")) {
      rgba = parseHex(value);
    } else if (namedColors.has(value.toLowerCase())) {
      rgba = [...namedColors.get(value.toLowerCase()), 1];
    } else {
      return value;
    }
    if (!rgba) return value;
    [hue, saturation, lightness] = rgbToHsl(rgba[0], rgba[1], rgba[2]);
    alpha = rgba[3];
  }

  const darkSaturation = Math.min(saturation * 0.82, 82);
  const output = `${alpha < 1 ? "hsla" : "hsl"}(${hue.toFixed(2)}, ${darkSaturation.toFixed(2)}%, ${darkLightness(lightness).toFixed(2)}%`;
  return alpha < 1 ? `${output}, ${alpha.toFixed(3)})` : `${output})`;
}

function transformPaint(value) {
  if (typeof value === "string") return darkColor(value);
  if (Array.isArray(value)) return value.map(transformPaint);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).map(([key, child]) => [key, transformPaint(child)]));
  }
  return value;
}

for (const layer of style.layers ?? []) {
  if (layer.paint) layer.paint = transformPaint(layer.paint);
}
if (style.light?.color) style.light.color = darkColor(style.light.color);
style.name = `${style.name ?? "Map"} Dark`;
style.metadata = {
  ...(style.metadata ?? {}),
  "cominavi:source-style": "https://americanamap.org/style.json",
  "cominavi:appearance": "dark",
};

fs.mkdirSync(path.dirname(outputPath), { recursive: true });
fs.writeFileSync(outputPath, `${JSON.stringify(style)}\n`);
