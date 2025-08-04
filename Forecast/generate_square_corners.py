#!/usr/bin/env python3
# generate_square_corners.py
"""
Generate square corner coordinates around a center point on the WGS84 ellipsoid.

Given a center latitude/longitude and a radius (in km), compute the 4 corner
coordinates of a square centered at that point, oriented with local East (x)
and North (y) axes (i.e., no rotation). The "radius" can be interpreted in
different ways (see --mode). Results use precise geodesic calculations and are
typically accurate to well under 1 meter when using GeographicLib.

USAGE
-----
  python generate_square_corners.py <lat> <lon> <radius_km> [--mode halfside|enclose-circle|inscribe-in-circle]
                                   [--precision 7] [--csv] [--json]

Examples:
  # Half-side = 25 km (square side = 50 km)
  python generate_square_corners.py 53.5461 -113.4938 25

  # Treat 25 km as a circle radius; square that *encloses* the circle
  # (half-side = 25 km; corner distance = 25*sqrt(2) km)
  python generate_square_corners.py 53.5461 -113.4938 25 --mode enclose-circle

  # Treat 25 km as a circle radius; square *inscribed* in the circle
  # (half-side = 25/sqrt(2) km; corner distance = 25 km)
  python generate_square_corners.py 53.5461 -113.4938 25 --mode inscribe-in-circle

OUTPUT
------
Prints a table of corners (NW, NE, SE, SW) with:
  - local offsets (east_km, north_km)
  - bearing from center and geodesic distance (km)
  - latitude, longitude (degrees)

Optionally emits a CSV or JSON block with the same data.

DEPENDENCIES
------------
Requires the "geographiclib" Python package for sub-meter geodesic accuracy:

  pip install geographiclib

If unavailable, the script will exit with an informative message.
"""

from __future__ import annotations
import argparse
import json
import math
import sys
from typing import Dict, List

try:
    from geographiclib.geodesic import Geodesic
except Exception as e:
    sys.stderr.write(
        "ERROR: This script requires the 'geographiclib' package for precise geodesic computations.\n"
        "Install with: pip install geographiclib\n"
    )
    raise


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Generate square corner coordinates around a center point on WGS84."
    )
    p.add_argument("lat", type=float, help="Center latitude in degrees (WGS84)")
    p.add_argument("lon", type=float, help="Center longitude in degrees (WGS84)")
    p.add_argument("radius_km", type=float, help="Radius value in kilometers")
    p.add_argument(
        "--mode",
        choices=["halfside", "enclose-circle", "inscribe-in-circle"],
        default="halfside",
        help=(
            "Interpretation of radius:\n"
            "  halfside: radius = half the square's side length (default)\n"
            "  enclose-circle: radius is circle radius; square ENcloses the circle (half-side = radius)\n"
            "  inscribe-in-circle: radius is circle radius; square INscribed in circle (half-side = radius/sqrt(2))"
        ),
    )
    p.add_argument(
        "--precision",
        type=int,
        default=7,
        help="Decimal places for lat/lon in output (default: 7 ~ centimeter scale).",
    )
    p.add_argument(
        "--csv",
        action="store_true",
        help="Emit CSV lines after the textual table.",
    )
    p.add_argument(
        "--json",
        action="store_true",
        help="Emit a JSON object after the textual table.",
    )
    return p.parse_args()


def hr_km(x_km: float) -> str:
    """Human-readable km with 3 decimal places."""
    return f"{x_km:.3f} km"


def bearing_deg_from_EN(east_km: float, north_km: float) -> float:
    """
    Compute initial bearing (azimuth) in degrees from local East/North offsets,
    where 0° = North, 90° = East. Uses atan2(east, north).
    """
    return (math.degrees(math.atan2(east_km, north_km)) + 360.0) % 360.0


def direct_from_center(lat: float, lon: float, azimuth_deg: float, distance_km: float) -> Dict[str, float]:
    """
    Solve the geodesic direct problem from (lat, lon), forward azimuth, distance.
    Returns a dict with 'lat', 'lon' of the target point.
    """
    g = Geodesic.WGS84.Direct(lat, lon, azimuth_deg, distance_km * 1000.0)  # meters
    # Normalize longitude to [-180, 180] for readability
    lon_norm = ((g["lon2"] + 180.0) % 360.0) - 180.0
    return {"lat": g["lat2"], "lon": lon_norm}


def compute_corners(lat: float, lon: float, radius_km: float, mode: str) -> List[Dict[str, float]]:
    """
    Compute the four square corners in local EN orientation.

    Returns list of dicts with keys:
      name (NW/NE/SE/SW), east_km, north_km, bearing_deg, distance_km, lat, lon
    """
    if mode == "halfside":
        half_side_km = radius_km
    elif mode == "enclose-circle":
        # Square that ENcloses a circle of given radius -> half-side = circle radius
        half_side_km = radius_km
    elif mode == "inscribe-in-circle":
        # Square INscribed in the circle -> half-side = r / sqrt(2)
        half_side_km = radius_km / math.sqrt(2.0)
    else:
        raise ValueError("Unknown mode")

    # Define nominal EN offsets (km) for the 4 corners (local, no rotation):
    # NW: (-half_side, +half_side), NE: (+half_side, +half_side),
    # SE: (+half_side, -half_side), SW: (-half_side, -half_side)
    corners_EN = [
        ("NW", -half_side_km, +half_side_km),
        ("NE", +half_side_km, +half_side_km),
        ("SE", +half_side_km, -half_side_km),
        ("SW", -half_side_km, -half_side_km),
    ]

    out: List[Dict[str, float]] = []
    for name, e_km, n_km in corners_EN:
        dist_km = math.hypot(e_km, n_km)
        az_deg = bearing_deg_from_EN(e_km, n_km)
        pt = direct_from_center(lat, lon, az_deg, dist_km)
        out.append(
            {
                "name": name,
                "east_km": e_km,
                "north_km": n_km,
                "bearing_deg": az_deg,
                "distance_km": dist_km,
                "lat": pt["lat"],
                "lon": pt["lon"],
            }
        )
    return out


def main():
    args = parse_args()

    lat = args.lat
    lon = args.lon
    radius_km = args.radius_km
    mode = args.mode
    prec = max(0, min(12, int(args.precision)))  # clamp a bit

    corners = compute_corners(lat, lon, radius_km, mode)

    # Header / summary
    side_km = (radius_km if mode in ("halfside", "enclose-circle") else radius_km / math.sqrt(2.0)) * 2.0
    diag_km = side_km * math.sqrt(2.0)
    print(f"Center (lat,lon): {lat:.{prec}f}, {lon:.{prec}f}")
    print(f"Mode           : {mode}")
    print(f"Half-side (km) : {side_km/2.0:.3f}  |  Side length: {hr_km(side_km)}  |  Diagonal: {hr_km(diag_km)}")
    print()
    print(f"{'Corner':<3}  {'east_km':>10}  {'north_km':>10}  {'bearing':>8}  {'dist_km':>9}  {'lat':>12}  {'lon':>13}")
    print("-" * 78)
    for c in corners:
        print(
            f"{c['name']:<3}  {c['east_km']:10.3f}  {c['north_km']:10.3f}  "
            f"{c['bearing_deg']:8.3f}  {c['distance_km']:9.3f}  "
            f"{c['lat']:.{prec}f}  {c['lon']:.{prec}f}"
        )

    if args.csv:
        # CSV header + rows
        print()
        print("name,east_km,north_km,bearing_deg,distance_km,lat,lon")
        for c in corners:
            print(
                f"{c['name']},{c['east_km']:.6f},{c['north_km']:.6f},"
                f"{c['bearing_deg']:.6f},{c['distance_km']:.6f},"
                f"{c['lat']:.{prec}f},{c['lon']:.{prec}f}"
            )

    if args.json:
        print()
        print(json.dumps(
            {
                "center": {"lat": lat, "lon": lon},
                "mode": mode,
                "half_side_km": (radius_km if mode in ("halfside", "enclose-circle") else radius_km / math.sqrt(2.0)),
                "side_km": side_km,
                "diagonal_km": diag_km,
                "corners": corners,
            },
            indent=2
        ))


if __name__ == "__main__":
    main()
