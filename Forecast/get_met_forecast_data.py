#!/usr/bin/env python3
"""
get_met_forecast_data.py  – v2  (2025‑08‑04)
----------------------------------------------------------
Creates gfs.cnf from user inputs, downloads GFS via download_gfs_file.sh.
Extended to carry start date, interval, case name, GEOG path
so that run_wrf.sh can run fully unattended.
"""
from __future__ import annotations
import argparse, datetime as dt, os, subprocess, sys
from typing import List, Tuple
try:
    from geographiclib.geodesic import Geodesic
except Exception:
    sys.stderr.write("Install 'geographiclib' (pip install geographiclib)\n")
    raise

# ---------------- helpers ----------------
def script_dir() -> str: return os.path.dirname(os.path.abspath(__file__))
def norm360(lon): x = lon % 360.0; return x if x >= 0 else x+360
def dest(lat, lon, az, km):
    r = Geodesic.WGS84.Direct(lat, lon, az, km*1000)
    return r["lat2"], ((r["lon2"]+180)%360)-180

def bounds(clat, clon, rad):
    n = dest(clat, clon,   0, rad)
    s = dest(clat, clon, 180, rad)
    e = dest(clat, clon,  90, rad)
    w = dest(clat, clon, 270, rad)
    top, bottom = max(n[0], s[0]), min(n[0], s[0])
    left, right = norm360(w[1]), norm360(e[1])
    if left > right: left, right = right, left
    return top, bottom, left, right

def make_intervals(total_d: float, step_h: int) -> List[str]:
    total_h = int(round(total_d*24))
    if total_h % step_h: total_h = (total_h//step_h)*step_h
    return [f"0 {step_h} {total_h}"]

def write_cnf(path, **kv):
    """
    Light wrapper that quotes values *only* when they contain spaces
    **and** do not already look like a bash array or are themselves quoted.
    """
    with open(path, "w") as f:
        f.write(f"# Auto‑generated {dt.datetime.utcnow():%Y-%m-%dT%H:%M:%SZ}\n")
        for k, v in kv.items():
            if (
                isinstance(v, str)
                and " " in v
                and not v.startswith("(")   # allow raw array e.g. (\"0 3 240\")
                and not v.startswith('"')
            ):
                v = f'"{v}"'
            f.write(f"{k}={v}\n")

def snap_end(start_dt: dt.datetime,
             days: float,
             interval_sec: int) -> dt.datetime:
    end = start_dt + dt.timedelta(days=days)
    span = (end - start_dt).total_seconds()
    end -= dt.timedelta(seconds = span % interval_sec)  # round down
    return end

# ---------------- CLI --------------------
def cli():
    ddir = script_dir()
    p = argparse.ArgumentParser()
    p.add_argument("lat", type=float); p.add_argument("lon", type=float)
    p.add_argument("radius_km", type=float)
    p.add_argument("forecast_days", type=float)
    p.add_argument("--start-date", required=True,
                   help="UTC YYYY-MM-DDTHH:MM")
    p.add_argument("--interval-hours", type=int, default=3)
    p.add_argument("--case-name", required=True)
    p.add_argument("--wrf-dest", required=True,
                   help="Root folder to place GFS tree (MET)")
    p.add_argument("--geog-data", required=True)
    p.add_argument("--resolution", choices=["0p25","0p50"], default="0p25")
    p.add_argument("--valid-hours", default="00|06|12|18")
    p.add_argument("--parallel", type=int, default=24)
    p.add_argument("--cycle", default="auto",
                   help="YYYYMMDDHH or 'auto' (snap start‑date to 6 h)")
    p.add_argument("--config-path", default=os.path.join(ddir,"gfs.cnf"))
    p.add_argument("--download-met-gfs-script", default=os.path.join(ddir,"download_met_gfs.sh"))
    p.add_argument("--dry-run", action="store_true")
    return p.parse_args()

# ---------------- main --------------------
def main():
    a = cli()
    top,bottom,left,right = bounds(a.lat,a.lon,a.radius_km)
    intervals = make_intervals(a.forecast_days, a.interval_hours)

    # --- cycle ---
    if a.cycle=="auto":
        dt0 = dt.datetime.strptime(a.start_date,"%Y-%m-%dT%H:%M")
        dt0 -= dt.timedelta(hours=dt0.hour % 6)
        cycle = dt0.strftime("%Y%m%d%H")
    else:
        cycle = a.cycle

    # -------------------------------------------------------------------
    start_dt  = dt.datetime.strptime(a.start_date, "%Y-%m-%dT%H:%M")
    end_dt    = snap_end(start_dt, a.forecast_days, a.interval_hours*3600)

    run_days  = int((end_dt - start_dt).days)         # whole days

    # components for namelist.input
    def comps(d): return d.year, d.month, d.day, d.hour
    sy,sm,sd,sh = comps(start_dt); ey,em,ed,eh = comps(end_dt)

    START_DATE = start_dt.strftime("%Y-%m-%d_%H:%M:%S")
    END_DATE   = end_dt .strftime("%Y-%m-%d_%H:%M:%S")

    # --- write gfs.cnf ---
    
    interval_items = " ".join(f'"{s}"' for s in intervals)      # →  "0 3 240"
    intervals_literal = f'({interval_items})'   
    
    write_cnf(a.config_path,
        FOLDER_NAME=a.case_name,
        TOP=f"{top:.8f}", BOTTOM=f"{bottom:.8f}",
        LEFT=f"{left:.8f}", RIGHT=f"{right:.8f}",
        INTERVALS=intervals_literal,
        RESOLUTION=a.resolution,
        VALID_HOURS=f"\"{a.valid_hours}\"",
        WRF_DEST=a.wrf_dest,
        CENTER_LAT=f"{a.lat:.6f}",
        CENTER_LON=f"{a.lon:.6f}",
        RADIUS_KM=int(round(a.radius_km)),
        START_DATE=START_DATE,
        END_DATE=END_DATE,
        RUN_DAYS=run_days,
        START_YEAR=sy, START_MONTH=f"{sm:02}", START_DAY=f"{sd:02}", START_HOUR=f"{sh:02}",
        END_YEAR=ey,   END_MONTH=f"{em:02}",   END_DAY=f"{ed:02}",   END_HOUR=f"{eh:02}",
        FORECAST_DAYS=a.forecast_days,
        GEOG_DATA_PATH=f"\"{a.geog_data}\"",
        CASE_NAME=f"\"{a.case_name}\"",
        CYCLE=cycle
    )
    print(f"✅  Wrote {a.config_path}")

    if a.dry_run:
        print("--dry-run → skip download")
        return

    # --- call downloader ---
    cmd=[a.download_met_gfs_script,"-c",a.config_path,"-P",str(a.parallel),"-D",cycle]
    subprocess.check_call(cmd)

if __name__=="__main__":
    main()
