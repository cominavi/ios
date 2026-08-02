#!/usr/bin/env python3
"""Local calibration server for aligning ComiNavi venue artwork to OSM."""

from __future__ import annotations

import argparse
import json
import math
import sqlite3
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlparse


TOOL_ROOT = Path(__file__).resolve().parent
PROJECT_ROOT = TOOL_ROOT.parents[1]
DEMO_C104_IMAGE_DATABASE = (
    PROJECT_ROOT
    / "ComiNavi"
    / "Resources"
    / "DemoCatalogs"
    / "C104"
    / "demo-c104-images.sqlite"
)
EVENT_NUMBER = 104
IMAGE_DATABASE = DEMO_C104_IMAGE_DATABASE
CALIBRATION_PATH = TOOL_ROOT / "calibration.json"
EARTH_RADIUS_METERS = 6_378_137.0


def offset_coordinate(
    latitude: float,
    longitude: float,
    *,
    east_meters: float,
    south_meters: float,
) -> tuple[float, float]:
    latitude_radians = math.radians(latitude)
    return (
        latitude - math.degrees(south_meters / EARTH_RADIUS_METERS),
        longitude
        + math.degrees(east_meters / (EARTH_RADIUS_METERS * math.cos(latitude_radians))),
    )


def display_path(path: Path) -> str:
    try:
        return str(path.relative_to(PROJECT_ROOT))
    except ValueError:
        return str(path)


def default_venues() -> list[dict[str, Any]]:
    if EVENT_NUMBER == 108:
        return c108_venues()

    east_latitude = 35.6317268
    east_longitude = 139.7977084
    east_rotation = -35.3203
    east_rotation_radians = math.radians(east_rotation)

    def east_row(identifier: str, name: str, image_name: str, side: float) -> dict[str, Any]:
        east_offset = -math.sin(east_rotation_radians) * 55 * side
        south_offset = math.cos(east_rotation_radians) * 55 * side
        latitude, longitude = offset_coordinate(
            east_latitude,
            east_longitude,
            east_meters=east_offset,
            south_meters=south_offset,
        )
        authored_rotation = 180 if identifier == "east456" else 0
        return venue(
            identifier,
            name,
            image_name,
            latitude,
            longitude,
            4_680 * 0.045,
            1_680 * 0.045,
            east_rotation + authored_rotation,
        )

    east7_rotation = -1.3746
    east7_rotation_radians = math.radians(east7_rotation)
    east7_latitude, east7_longitude = offset_coordinate(
        35.6331039,
        139.7991998,
        east_meters=-math.sin(east7_rotation_radians) * 60,
        south_meters=math.cos(east7_rotation_radians) * 60,
    )

    return [
        east_row("east123", "East 1–3", "LWMP1E123", 1),
        east_row("east456", "East 4–6", "LWMP1E456", -1),
        venue(
            "east7",
            "East 7",
            "LWMP1E7",
            east7_latitude,
            east7_longitude,
            2_440 * 0.045,
            2_640 * 0.045,
            east7_rotation,
        ),
        venue(
            "west",
            "West Halls",
            "LWMP1W12",
            35.6288139,
            139.7950394,
            3_600 * 0.045,
            2_560 * 0.045,
            -56.0936,
        ),
    ]


def c108_venues() -> list[dict[str, Any]]:
    return [
        venue(
            "east123",
            "East 1–3",
            "LWMP1E123",
            35.631057820055005,
            139.79794721575166,
            275.8224542031329,
            103.72809983536542,
            146.462,
        ),
        venue(
            "east7",
            "East 7",
            "LWMP1E7",
            35.633471367816355,
            139.7994204284449,
            113.01855361967942,
            122.28236949014496,
            -33.40707083299674,
        ),
        venue(
            "west",
            "West Halls",
            "LWMP1W12",
            35.62877144202331,
            139.79501092499783,
            205.27930023717607,
            152.81943451220807,
            146.97977914964463,
        ),
        venue(
            "south",
            "South 1–2",
            "LWMP1S12",
            35.6276546,
            139.7949281,
            111.6,
            61.2,
            50.8873,
        ),
    ]


def venue(
    identifier: str,
    name: str,
    image_name: str,
    latitude: float,
    longitude: float,
    width_meters: float,
    height_meters: float,
    rotation_degrees: float,
) -> dict[str, Any]:
    return {
        "id": identifier,
        "name": name,
        "imageName": image_name,
        "latitude": latitude,
        "longitude": longitude,
        "widthMeters": width_meters,
        "heightMeters": height_meters,
        "rotationDegrees": rotation_degrees,
        "opacity": 0.72,
        "visible": True,
    }


def merged_configuration() -> dict[str, Any]:
    defaults = default_venues()
    saved: dict[str, Any] = {}
    if CALIBRATION_PATH.exists():
        try:
            saved = json.loads(CALIBRATION_PATH.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            saved = {}

    saved_by_id = {
        item.get("id"): item
        for item in saved.get("venues", [])
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    }
    merged = []
    for item in defaults:
        merged.append({**item, **saved_by_id.get(item["id"], {})})
    return {
        "event": EVENT_NUMBER,
        "imageDatabase": display_path(IMAGE_DATABASE),
        "calibrationFile": str(CALIBRATION_PATH.relative_to(PROJECT_ROOT)),
        "savedAt": saved.get("savedAt"),
        "venues": merged,
    }


def validate_payload(payload: Any) -> dict[str, Any]:
    if not isinstance(payload, dict) or not isinstance(payload.get("venues"), list):
        raise ValueError("Expected an object containing a venues array")

    expected_ids = {item["id"] for item in default_venues()}
    venues = payload["venues"]
    if {item.get("id") for item in venues if isinstance(item, dict)} != expected_ids:
        raise ValueError("Calibration must contain every known venue exactly once")

    numeric_fields = (
        "latitude",
        "longitude",
        "widthMeters",
        "heightMeters",
        "rotationDegrees",
        "opacity",
    )
    for item in venues:
        if not isinstance(item, dict):
            raise ValueError("Every venue must be an object")
        for field in numeric_fields:
            value = item.get(field)
            if not isinstance(value, (int, float)) or not math.isfinite(value):
                raise ValueError(f"{item.get('id', 'venue')}.{field} must be finite")
        if item["widthMeters"] <= 1 or item["heightMeters"] <= 1:
            raise ValueError("Venue dimensions must be greater than one meter")
        if not -90 <= item["latitude"] <= 90 or not -180 <= item["longitude"] <= 180:
            raise ValueError("Venue coordinates are outside valid geographic bounds")
        if not 0.05 <= item["opacity"] <= 1:
            raise ValueError("Venue opacity must be between 0.05 and 1")

    return {
        "event": EVENT_NUMBER,
        "savedAt": datetime.now(timezone.utc).isoformat(),
        "venues": venues,
    }


class CalibrationHandler(BaseHTTPRequestHandler):
    server_version = "ComiNaviCalibration/1.0"

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        if parsed.path in ("/", "/index.html"):
            self.send_file(TOOL_ROOT / "index.html", "text/html; charset=utf-8")
            return
        if parsed.path == "/api/config":
            self.send_json(merged_configuration())
            return
        if parsed.path.startswith("/api/image/"):
            self.send_database_image(unquote(parsed.path.removeprefix("/api/image/")))
            return
        if parsed.path == "/health":
            self.send_json({"ok": True})
            return
        self.send_error(HTTPStatus.NOT_FOUND)

    def do_POST(self) -> None:  # noqa: N802
        if urlparse(self.path).path != "/api/calibration":
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > 1_000_000:
                raise ValueError("Invalid request size")
            payload = json.loads(self.rfile.read(length))
            validated = validate_payload(payload)
            temporary_path = CALIBRATION_PATH.with_suffix(".json.tmp")
            temporary_path.write_text(
                json.dumps(validated, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )
            temporary_path.replace(CALIBRATION_PATH)
            self.send_json(
                {
                    "ok": True,
                    "savedAt": validated["savedAt"],
                    "path": str(CALIBRATION_PATH.relative_to(PROJECT_ROOT)),
                }
            )
        except (ValueError, json.JSONDecodeError, OSError) as error:
            self.send_json({"ok": False, "error": str(error)}, HTTPStatus.BAD_REQUEST)

    def send_database_image(self, name: str) -> None:
        allowed_names = {item["imageName"] for item in default_venues()}
        if name not in allowed_names:
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        try:
            with sqlite3.connect(f"file:{IMAGE_DATABASE}?mode=ro", uri=True) as database:
                row = database.execute(
                    "SELECT type, image FROM ComiketCommonImage WHERE name = ? LIMIT 1",
                    (name,),
                ).fetchone()
        except sqlite3.Error as error:
            self.send_error(HTTPStatus.INTERNAL_SERVER_ERROR, str(error))
            return
        if row is None or row[1] is None:
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        media_type = "image/png" if row[0] == "png" else "application/octet-stream"
        body = bytes(row[1])
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", media_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def send_file(self, path: Path, content_type: str) -> None:
        try:
            body = path.read_bytes()
        except OSError:
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, payload: Any, status: HTTPStatus = HTTPStatus.OK) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, message_format: str, *args: object) -> None:
        print(f"[{self.log_date_time_string()}] {message_format % args}")


def discover_simulator_image_database(event_number: int) -> Path | None:
    event_ids = {104: 190, 108: 230}
    event_id = event_ids.get(event_number)
    if event_id is None:
        return None

    devices_root = Path.home() / "Library" / "Developer" / "CoreSimulator" / "Devices"
    pattern = (
        "*/data/Containers/Data/Application/*/Library/Caches/environments/*/*/events/"
        f"event-{event_id}/comiket-{event_number}/circlems/databases/image.sqlite"
    )
    candidates = [path for path in devices_root.glob(pattern) if path.is_file()]
    if not candidates:
        return None
    return max(candidates, key=lambda path: path.stat().st_mtime)


def main() -> None:
    global CALIBRATION_PATH, EVENT_NUMBER, IMAGE_DATABASE

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--event", type=int, choices=(104, 108), default=108)
    parser.add_argument(
        "--image-database",
        type=Path,
        help="Override the Circle.ms image SQLite database used by the selected event.",
    )
    args = parser.parse_args()

    EVENT_NUMBER = args.event
    CALIBRATION_PATH = TOOL_ROOT / (
        "calibration.json" if EVENT_NUMBER == 104 else f"calibration-c{EVENT_NUMBER}.json"
    )
    if args.image_database is not None:
        IMAGE_DATABASE = args.image_database.expanduser().resolve()
    elif EVENT_NUMBER == 104:
        IMAGE_DATABASE = DEMO_C104_IMAGE_DATABASE
    else:
        discovered_database = discover_simulator_image_database(EVENT_NUMBER)
        if discovered_database is None:
            raise SystemExit(
                f"Missing C{EVENT_NUMBER} image database. Download the catalog in the simulator "
                "or pass --image-database PATH."
            )
        IMAGE_DATABASE = discovered_database

    if not IMAGE_DATABASE.exists():
        raise SystemExit(
            f"Missing C{EVENT_NUMBER} image database. Download the catalog in the simulator "
            "or pass --image-database PATH."
        )

    address = ("127.0.0.1", args.port)
    server = ThreadingHTTPServer(address, CalibrationHandler)
    print(f"ComiNavi C{EVENT_NUMBER} map calibration: http://{address[0]}:{address[1]}")
    print(f"Artwork database: {IMAGE_DATABASE}")
    print(f"Saving alignments to: {CALIBRATION_PATH}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
