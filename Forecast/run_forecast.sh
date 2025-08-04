#!/usr/bin/env bash
# run_forecast.sh
# High‑level one‑liner driver: downloads GFS, runs WPS + WRF.
# Requires that `direnv` auto‑activates the repo environment.
#
# USAGE (example)
#   ./run_forecast.sh \
#        --lat 53.5461 --lon -113.4938 \
#        --radius-km 150 \
#        --start-date "2025-08-05T00:00" \
#        --forecast-days 3 \
#        --interval-hours 3 \
#        --case-name EDMONTON_TEST \
#        --download-root /mnt/node0-bulk1/MET \
#        --case-root     /mnt/node0-bulk1/WRF_CASES \
#        --geog-data     /mnt/node0-bulk1/MET/GEOG/WPS_GEOG
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${DIR}/.." && pwd)"

# ---------------- CLI -------------------------------------------------
usage() {
  grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}
LAT="" LON="" RADIUS_KM="" FORECAST_DAYS="" INTERVAL_H=3
# sensible repo‑wide defaults
START_DATE="$(date -u '+%Y-%m-%dT%H:00' | sed -r 's/([0-9]{2})$/00/')" # rounded later
DOWNLOAD_ROOT="/mnt/node0-bulk1/MET"
CASE_ROOT="/mnt/node0-bulk1/MET/WRF_OUT"
GEOG_DATA="/mnt/node0-bulk1/MET/GEOG/WPS_GEOG"
CASE_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lat) LAT=$2; shift 2;;
    --lon) LON=$2; shift 2;;
    --radius-km) RADIUS_KM=$2; shift 2;;
    --start-date) START_DATE=$2; shift 2;;
    --forecast-days) FORECAST_DAYS=$2; shift 2;;
    --interval-hours) INTERVAL_H=$2; shift 2;;
    --case-name) CASE_NAME=$2; shift 2;;
    --download-root) DOWNLOAD_ROOT=$2; shift 2;;
    --case-root) CASE_ROOT=$2; shift 2;;
    --geog-data) GEOG_DATA=$2; shift 2;;
    -h|--help) usage;;
    *) echo "Unknown arg: $1"; usage;;
  esac
done
[[ -z "$LAT$LON$RADIUS_KM$START_DATE$FORECAST_DAYS$CASE_NAME$DOWNLOAD_ROOT$CASE_ROOT$GEOG_DATA" ]] && usage
(( FORECAST_DAYS <= 10 )) || { echo "forecast-days may not exceed 10"; exit 1; }

# -------------- environment (direnv already in bashrc) ----------------
eval "$(direnv export bash)"           # makes modulefiles and python venv available

export CASE_ROOT                     # passed through to run_wrf.sh
export FORCE_NEW_CASE=1              # overwrite case without prompt

# -------------- step 1: download & prep GFS ----------------------------
python "$DIR/get_met_forecast_data.py" \
       "$LAT" "$LON" "$RADIUS_KM" "$FORECAST_DAYS" \
       --start-date "$START_DATE" \
       --interval-hours "$INTERVAL_H" \
       --case-name "$CASE_NAME" \
       --wrf-dest "$DOWNLOAD_ROOT" \
       --geog-data "$GEOG_DATA" \
       --parallel 24 \
       --cycle auto

# -------------- step 2: run WPS + WRF ---------------------------------
bash "$DIR/run_wrf.sh" "$DIR/gfs.cnf"

echo "✅  Finished.  WRF outputs in:  ${CASE_ROOT}/${CASE_NAME}"
