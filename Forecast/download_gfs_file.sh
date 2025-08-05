#!/bin/bash
# download_gfs_files.sh
#
# ===============================================
# GFS download for WRF model (cycle subfolders, CSV logging, parallel)
# Author: Mikael Hasu (orig), updated by Scott Bell
# Modified from: https://github.com/fmidev/WRF_installation
# Date: July 2025
# ===============================================
#

set -Eeuo pipefail

# ----------------- Script dir & defaults -----------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# If -c is not provided, we try to find a config in the script directory.
# Prefer gfs.cnf, fall back to gfs.cfg. You can change this order if you like.
CONFIG_PATH=""        # set by -c or auto-detected below

# ----------------- CLI flags ---------------------------
# -c /path/to/gfs.cnf  (config file path)
# -D YYYYMMDDHH        (force cycle)
# -d                   (dry run)
# -g <res>             (0p25|0p50)
# -i "<start step end>"
# -l,-r,-t,-b          (bounds)
# -v                   (VALID_HOURS)
# -P <int>             (parallelism; default 24)
DRYRUN=""
MAX_PAR="${MAX_PAR:-24}"
RT_OVERRIDE=""

while getopts "c:a:b:dD:g:i:l:r:t:v:P:" flag; do
  case "$flag" in
    c) CONFIG_PATH=$OPTARG;;
    a) FOLDER_NAME=$OPTARG;;      # -a sets FOLDER_NAME (not AREA)    
    b) BOTTOM=$OPTARG;;
    d) DRYRUN=1;;
    D) RT_OVERRIDE=$OPTARG;;                          # expects YYYYMMDDHH
    g) RESOLUTION=$OPTARG;;
    i) INTERVALS=("$OPTARG");;
    l) LEFT=$OPTARG;;
    r) RIGHT=$OPTARG;;
    t) TOP=$OPTARG;;
    v) VALID_HOURS=$OPTARG;;
    P) MAX_PAR=$OPTARG;;
    *) echo "Usage: $0 [-c CONFIG] [-D YYYYMMDDHH] [-P N] [-d] [-g 0p25|0p50] [-i \"start step end\"] [-l L] [-r R] [-t T] [-b B] [-v HOURS]"; exit 2;;
  esac
done

# ----------------- Select/load configuration -----------------
if [[ -z "$CONFIG_PATH" ]]; then
  # Auto-detect in script dir
  if   [[ -r "$SCRIPT_DIR/gfs.cnf" ]]; then CONFIG_PATH="$SCRIPT_DIR/gfs.cnf"
  elif [[ -r "$SCRIPT_DIR/gfs.cfg" ]]; then CONFIG_PATH="$SCRIPT_DIR/gfs.cfg"
  else
    echo "ERROR: No config file found. Pass -c /path/to/gfs.cnf (or place gfs.cnf/.cfg next to get_gfs.sh)." >&2
    exit 2
  fi
fi

if [[ ! -r "$CONFIG_PATH" ]]; then
  echo "ERROR: Config not readable: $CONFIG_PATH" >&2
  exit 2
fi

echo "Using config: $CONFIG_PATH"
# shellcheck source=/dev/null
. "$CONFIG_PATH"

# ----------------- Back-compat defaults & AREA from FOLDER_NAME -----------------
# Ensure variables exist even under 'set -u'
: "${FOLDER_NAME:=}"
: "${TOP:=90}"
: "${BOTTOM:=-90}"
: "${LEFT:=0}"
: "${RIGHT:=360}"
: "${INTERVALS:=0 3 24}"
: "${RESOLUTION:=0p25}"
: "${VALID_HOURS:=00|06|12|18}"
: "${WRF_DEST:=${WRF_COPY_DEST:-/home/wrf/WRF_Model/MET}}"

# Derive AREA:
# 1) If AREA already set, keep it.
# 2) Else if FOLDER_NAME set, use it.
# 3) Else, if bounds exist, use lat/lon center.
# 4) Else, fall back to 'world'.
if [[ -z "${AREA:-}" ]]; then
  if [[ -n "$FOLDER_NAME" ]]; then
    AREA="$FOLDER_NAME"
  elif [[ -n "${TOP:-}" && -n "${BOTTOM:-}" && -n "${LEFT:-}" && -n "${RIGHT:-}" ]]; then
    center_lat=$(awk "BEGIN { printf \"%.3f\", (${TOP}+${BOTTOM})/2.0 }")
    center_lon=$(awk "BEGIN { printf \"%.3f\", (${LEFT}+${RIGHT})/2.0 }")
    AREA="lat${center_lat}_lon${center_lon}"
  else
    AREA="world"
  fi
fi

command -v seq >/dev/null 2>&1 || { echo "ERROR: 'seq' not found"; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "ERROR: 'curl' not found"; exit 2; }

# ----- Pad edges to ensure full domain coverage for WRF -----------------------
# ----- padding the lat‑lon box by minimum of one degree in all directions -----
# pad by 10 % of span (or at least 2°)
dlat=$(awk "BEGIN {print (${TOP}-${BOTTOM})*0.10 }")
dlon=$(awk "BEGIN {print (${RIGHT}-${LEFT})*0.10 }")
(( $(echo "$dlat < 1.0" | bc -l) )) && dlat=1
(( $(echo "$dlon < 1.0" | bc -l) )) && dlon=1

PAD_TOP=$(awk "BEGIN {print (${TOP}+dlat>90)?90:${TOP}+dlat}")
PAD_BOTTOM=$(awk "BEGIN {print (${BOTTOM}-dlat<-90)?-90:${BOTTOM}-dlat}")
PAD_LEFT=$(awk "BEGIN {print (${LEFT}-dlon<0)?0:${LEFT}-dlon}")
PAD_RIGHT=$(awk "BEGIN {print (${RIGHT}+dlon>360)?360:${RIGHT}+dlon}")


# ----------------- Helpers ----------------------------
hr_size() { # bytes -> human readable (B/KB/MB/GB/TB), base 1024
  local b=$1 u=(B KB MB GB TB) i=0
  while (( b >= 1024 && i < ${#u[@]}-1 )); do
    b=$(( (b + 512) / 1024 ))
    (( ++i ))
  done
  echo "${b}${u[$i]}"
}

log() { echo "$(date -u +%H:%M:%S) $*"; }

have_grib_count=0
if command -v grib_count >/dev/null 2>&1; then
  have_grib_count=1
fi

# ----------------- Model Reference Time -----------------

# CYCLE is e.g. 2025080418
if [[ -n "$RT_OVERRIDE" ]]; then
    CYCLE="$RT_OVERRIDE"
fi
if [[ ! "$CYCLE" =~ ^[0-9]{10}$ ]]; then
    echo "ERROR: CYCLE must be YYYYMMDDHH (got '$CYCLE')" >&2; exit 2
fi
RT_DATE=${CYCLE:0:8}
RT_HOUR=${CYCLE:8:2}
RT_DATE_HH="$CYCLE"
RT_ISO="$(date -u -d "${RT_DATE} ${RT_HOUR}:00" +%Y-%m-%dT%H:%M:%SZ)"
RT=$(date -u -d "${RT_DATE} ${RT_HOUR}:00" +%s)


# ----------------- Paths / Logs ------------------------
DEST_ROOT="$WRF_DEST"
DEST_DIR="$DEST_ROOT/$AREA/$RT_DATE_HH"        # cycle subfolder
LOG_DIR="$DEST_ROOT/log"
CSV_LOG="$LOG_DIR/gfs_download_log.txt"
mkdir -p "$DEST_DIR" "$LOG_DIR"

# CSV header (create if missing)
if [[ ! -s "$CSV_LOG" ]]; then
  echo "timestamp_utc,cycle,folder,resolution,left,right,top,bottom,interval,step,filesize_bytes,filesize_hr,grib_msgs,elapsed_sec,status,url,dest_file" >> "$CSV_LOG"
fi

# ----------------- URL builder -------------------------
# Global dataset left in for now to avoid unexplained errors in WPS
buildURL() {
  local file="$1"
#  echo "https://nomads.ncep.noaa.gov/cgi-bin/filter_gfs_${RESOLUTION}.pl?file=${file}&lev_1_mb=on&lev_2_mb=on&lev_3_mb=on&lev_5_mb=on&lev_7_mb=on&lev_10_mb=on&lev_15_mb=on&lev_20_mb=on&lev_30_mb=on&lev_40_mb=on&lev_50_mb=on&lev_70_mb=on&lev_100_mb=on&lev_150_mb=on&lev_200_mb=on&lev_250_mb=on&lev_300_mb=on&lev_350_mb=on&lev_400_mb=on&lev_450_mb=on&lev_500_mb=on&lev_550_mb=on&lev_600_mb=on&lev_650_mb=on&lev_700_mb=on&lev_750_mb=on&lev_800_mb=on&lev_850_mb=on&lev_900_mb=on&lev_925_mb=on&lev_950_mb=on&lev_975_mb=on&lev_1000_mb=on&lev_surface=on&lev_2_m_above_ground=on&lev_10_m_above_ground=on&lev_mean_sea_level=on&lev_entire_atmosphere=on&lev_entire_atmosphere_%5C%28considered_as_a_single_layer%5C%29=on&lev_low_cloud_layer=on&lev_middle_cloud_layer=on&lev_high_cloud_layer=on&lev_convective_cloud_layer=on&lev_0-0.1_m_below_ground=on&lev_0.1-0.4_m_below_ground=on&lev_0.4-1_m_below_ground=on&lev_1-2_m_below_ground=on&lev_1000_mb=on&lev_tropopause=on&lev_max_wind=on&lev_80_m_above_ground=on&var_CAPE=on&var_CIN=on&var_GUST=on&var_HGT=on&var_ICEC=on&var_LAND=on&var_PEVPR=on&var_PRATE=on&var_PRES=on&var_PRMSL=on&var_PWAT=on&var_RH=on&var_SHTFL=on&var_SNOD=on&var_SOILW=on&var_TSOIL=on&var_MSLET=on&var_SPFH=on&var_TCDC=on&var_TMP=on&var_DPT=on&var_UGRD=on&var_VGRD=on&var_DZDT=on&var_CNWAT=on&var_WEASD=on&subregion=on&leftlon=${PAD_LEFT}&rightlon=${PAD_RIGHT}&toplat=${PAD_TOP}&bottomlat=${PAD_BOTTOM}&dir=%2Fgfs.${RT_DATE}%2F${RT_HOUR}%2Fatmos"
  # replaced with global dataset for debugging
  echo "https://nomads.ncep.noaa.gov/cgi-bin/filter_gfs_${RESOLUTION}.pl?file=${file}&lev_1_mb=on&lev_2_mb=on&lev_3_mb=on&lev_5_mb=on&lev_7_mb=on&lev_10_mb=on&lev_15_mb=on&lev_20_mb=on&lev_30_mb=on&lev_40_mb=on&lev_50_mb=on&lev_70_mb=on&lev_100_mb=on&lev_150_mb=on&lev_200_mb=on&lev_250_mb=on&lev_300_mb=on&lev_350_mb=on&lev_400_mb=on&lev_450_mb=on&lev_500_mb=on&lev_550_mb=on&lev_600_mb=on&lev_650_mb=on&lev_700_mb=on&lev_750_mb=on&lev_800_mb=on&lev_850_mb=on&lev_900_mb=on&lev_925_mb=on&lev_950_mb=on&lev_975_mb=on&lev_1000_mb=on&lev_surface=on&lev_2_m_above_ground=on&lev_10_m_above_ground=on&lev_mean_sea_level=on&lev_entire_atmosphere=on&lev_entire_atmosphere_%5C%28considered_as_a_single_layer%5C%29=on&lev_low_cloud_layer=on&lev_middle_cloud_layer=on&lev_high_cloud_layer=on&lev_convective_cloud_layer=on&lev_0-0.1_m_below_ground=on&lev_0.1-0.4_m_below_ground=on&lev_0.4-1_m_below_ground=on&lev_1-2_m_below_ground=on&lev_tropopause=on&lev_max_wind=on&lev_80_m_above_ground=on&var_CAPE=on&var_CIN=on&var_GUST=on&var_HGT=on&var_ICEC=on&var_LAND=on&var_PEVPR=on&var_PRATE=on&var_PRES=on&var_PRMSL=on&var_PWAT=on&var_RH=on&var_SHTFL=on&var_SNOD=on&var_SOILW=on&var_TSOIL=on&var_MSLET=on&var_SPFH=on&var_TCDC=on&var_TMP=on&var_DPT=on&var_UGRD=on&var_VGRD=on&var_DZDT=on&var_CNWAT=on&var_WEASD=on&dir=%2Fgfs.${RT_DATE}%2F${RT_HOUR}%2Fatmos"
}

# ----------------- Validation --------------------------
testFile() {
  local file="$1"
  if [[ -s "$file" ]]; then
    if [[ "$have_grib_count" -eq 1 ]]; then
      local msgs; msgs="$(grib_count "$file" 2>/dev/null || echo 0)"
      [[ "$msgs" -gt 0 ]] && return 0
    else
      return 0
    fi
    rm -f -- "$file"
  fi
  return 1
}

write_csv() {
  local timestamp="$1" cycle="$2" folder="$3" res="$4" left="$5" right="$6" top="$7" bottom="$8" interval="$9" step="${10}" sizeB="${11}" sizeHR="${12}" msgs="${13}" elapsed="${14}" status="${15}" url="${16}" dest="${17}"
  printf '%s,%s,%s,%s,%s,%s,%s,%s,"%s",%s,%s,%s,%s,%s,%s,"%s","%s"\n' \
    "$timestamp" "$cycle" "$folder" "$res" "$left" "$right" "$top" "$bottom" "$interval" "$step" "$sizeB" "$sizeHR" "$msgs" "$elapsed" "$status" "$url" "$dest" >> "$CSV_LOG"
}

# ----------------- Download one step -------------------
downloadStep() {
  # Inputs
  local interval_str="$1"   # "start step end"
  local fhr="$2"            # numeric forecast hour

  # Derived values
  local step; step=$(printf '%03d' "$fhr")

  local file
  if [[ "$RESOLUTION" == "0p50" ]]; then
    file="gfs.t${RT_HOUR}z.pgrb2full.${RESOLUTION}.f${step}"
  else
    file="gfs.t${RT_HOUR}z.pgrb2.${RESOLUTION}.f${step}"
  fi

  local dest="$DEST_DIR/$file"
  local url; url="$(buildURL "$file")"

  # Timing
  local t0 t1 elapsed sizeB sizeHR msgs status
  t0="$(date -u +%s)"

  # Cached?
  if testFile "$dest"; then
    sizeB="$(stat -c '%s' "$dest" 2>/dev/null || echo 0)"
    sizeHR="$(hr_size "$sizeB")"
    msgs="$([[ "$have_grib_count" -eq 1 ]] && grib_count "$dest" 2>/dev/null || echo 0)"
    t1="$(date -u +%s)"; elapsed=$((t1 - t0))
    log "CACHED: $file size=${sizeHR} msgs=${msgs} t=${elapsed}s"
    write_csv "$(date -u +%FT%TZ)" "$RT_DATE_HH" "$AREA" "$RESOLUTION" "$LEFT" "$RIGHT" "$TOP" "$BOTTOM" "$interval_str" "$step" "$sizeB" "$sizeHR" "$msgs" "$elapsed" "CACHED" "$url" "$dest"
    return 0
  fi

  # Download & validate (retry up to 60 minutes)
  local tries=0
  while (( tries < 60 )); do
    (( ++tries ))
    log "GET: $file (try $tries)"
    if curl -s -S --fail -o "$dest" "$url"; then
      if testFile "$dest"; then
        sizeB="$(stat -c '%s' "$dest" 2>/dev/null || echo 0)"
        sizeHR="$(hr_size "$sizeB")"
        msgs="$([[ "$have_grib_count" -eq 1 ]] && grib_count "$dest" 2>/dev/null || echo 0)"
        t1="$(date -u +%s)"; elapsed=$((t1 - t0))
        status="OK"
        log "OK: $file size=${sizeHR} msgs=${msgs} t=${elapsed}s"
        write_csv "$(date -u +%FT%TZ)" "$RT_DATE_HH" "$AREA" "$RESOLUTION" "$LEFT" "$RIGHT" "$TOP" "$BOTTOM" "$interval_str" "$step" "$sizeB" "$sizeHR" "$msgs" "$elapsed" "$status" "$url" "$dest"
        return 0
      else
        rm -f -- "$dest" || true
      fi
    fi
    sleep 60
  done

  # Failure
  t1="$(date -u +%s)"; elapsed=$((t1 - t0))
  sizeB="$([[ -f "$dest" ]] && stat -c '%s' "$dest" || echo 0)"
  sizeHR="$(hr_size "$sizeB")"
  msgs="0"; status="FAIL"
  log "FAIL: $file size=${sizeHR} t=${elapsed}s  (see $CSV_LOG)"
  write_csv "$(date -u +%FT%TZ)" "$RT_DATE_HH" "$AREA" "$RESOLUTION" "$LEFT" "$RIGHT" "$TOP" "$BOTTOM" "$interval_str" "$step" "$sizeB" "$sizeHR" "$msgs" "$elapsed" "$status" "$url" "$dest"
  return 1
}

# ----- probe that the reference cycle exists on NOMADS -----------------

first_file="gfs.t${RT_HOUR}z.pgrb2.${RESOLUTION}.f000"
probe_url=$(buildURL "$first_file")

if ! curl -s --head --fail "$probe_url" >/dev/null; then
    log "WARN: cycle $RT_DATE_HH not yet on NOMADS – falling back 6 h."
    RT=$(( RT - 21600 ))                # minus 6 hours
    RT_DATE=$(date -u -d@"$RT" +%Y%m%d)
    RT_HOUR=$(date -u -d@"$RT" +%H)
    RT_DATE_HH=$(date -u -d@"$RT" +%Y%m%d%H)
    CYCLE="$RT_DATE_HH"
    RT_ISO=$(date -u -d@"$RT" +%Y-%m-%dT%H:%M:%SZ)
    DEST_DIR="$DEST_ROOT/$AREA/$RT_DATE_HH"
    mkdir -p "$DEST_DIR"
        
    # Keep later steps in sync ─ overwrite (or append) CYCLE in gfs.cnf
    if grep -q '^CYCLE=' "$CONFIG_PATH"; then
        sed -i "s/^CYCLE=.*/CYCLE=${CYCLE}/" "$CONFIG_PATH"
    else
        echo "CYCLE=${CYCLE}" >> "$CONFIG_PATH"
    fi

fi

##############################################################################
# ✦ Re‑sync START_DATE / END_DATE / INTERVALS in gfs.cnf to the new CYCLE
##############################################################################
# helper: write (or replace) a single KEY=value line in the cnf
set_cfg() {               # key  value
    if grep -q "^$1=" "$CONFIG_PATH"; then
        sed -i "s|^$1=.*|$1=$2|" "$CONFIG_PATH"
    else
        echo "$1=$2" >> "$CONFIG_PATH"
    fi
}

# Assume new cycle is in CYCLE, RT, etc. after the rollback!
max_fhr=240      # for GFS 0p25, max forecast hour (change if you want less)

# If this is the first download after fallback, start at 0h (cycle time).
snap_offset=0
start_epoch=$RT   # RT = epoch of new CYCLE start
end_epoch=$(( RT + max_fhr * 3600 ))  # always snap to the max available

new_START_DATE=$(date -u -d "@$start_epoch" +%Y-%m-%d_%H:%M:%S)
new_END_DATE=$(date -u -d "@$end_epoch" +%Y-%m-%d_%H:%M:%S)

set_cfg START_DATE "$new_START_DATE"
set_cfg END_DATE   "$new_END_DATE"

set_cfg START_YEAR $(date -u -d "@$start_epoch" +%Y)
set_cfg START_MONTH $(date -u -d "@$start_epoch" +%m)
set_cfg START_DAY   $(date -u -d "@$start_epoch" +%d)
set_cfg START_HOUR  $(date -u -d "@$start_epoch" +%H)

set_cfg END_YEAR $(date -u -d "@$end_epoch" +%Y)
set_cfg END_MONTH $(date -u -d "@$end_epoch" +%m)
set_cfg END_DAY   $(date -u -d "@$end_epoch" +%d)
set_cfg END_HOUR  $(date -u -d "@$end_epoch" +%H)

run_days=$(( (end_epoch - start_epoch) / 86400 ))
set_cfg RUN_DAYS "$run_days"

set_cfg INTERVALS "(\"0 3 $max_fhr\")"



##############################################################################
# ✦ 0. fast‑fail on directory problems
##############################################################################
#for d in "$WRF_DEST" "$DEST_ROOT" "$LOG_DIR"; do
#    [[ -d $d && -w $d ]] || {
#        echo "ERROR: directory $d missing or not writable" >&2
#        exit 2
#    }
#done
#mkdir -p   "$DEST_DIR"   # still create the leaf if the tree is good

##############################################################################
# ✦ 1. build the full list of URLs we need for this cycle
##############################################################################
#build_needed_urls() {
#    local urls=()
#    for interval in "${INTERVALS[@]}"; do
#        read -r istart istep iend <<<"$interval"
#        for fhr in $(seq "$istart" "$istep" "$iend"); do
#            urls+=( "$(buildURL "gfs.t${RT_HOUR}z.pgrb2.${RESOLUTION}.f$(printf '%03d' "$fhr")")" )
#        done
#    done
#    printf '%s\n' "${urls[@]}"
#}

##############################################################################
# ✦ 2. probe ALL the URLs; retry by cycling backwards until complete
##############################################################################
#max_back=4           # try current + 4 earlier cycles (24 h)
#while (( max_back-- >= 0 )); do
#    missing=0
#    while read -r u; do
#        curl -s --head --fail "$u" >/dev/null || (( missing++ ))
#    done < <(build_needed_urls)
#
#    if (( missing == 0 )); then
#        echo "All files present for cycle $RT_DATE_HH – proceeding."
#        break
#    fi

#    echo "Cycle $RT_DATE_HH incomplete ($missing files missing) – try previous cycle."
#    # go back 6 h
#    RT=$(( RT - 21600 ))
#    RT_DATE=$(date -u -d@"$RT" +%Y%m%d)
#    RT_HOUR=$(date -u -d@"$RT" +%H)
#    RT_DATE_HH=${RT_DATE}${RT_HOUR}
#    CYCLE=$RT_DATE_HH
#    DEST_DIR="$DEST_ROOT/$AREA/$RT_DATE_HH"
#    mkdir -p "$DEST_DIR"
#    # write the new cycle back to gfs.cnf so WPS/WRF stay consistent
#    if grep -q '^CYCLE=' "$CONFIG_PATH"; then
#        sed -i "s/^CYCLE=.*/CYCLE=${CYCLE}/" "$CONFIG_PATH"
#    else
#        echo "CYCLE=${CYCLE}" >> "$CONFIG_PATH"
#    fi
#done

#if (( missing > 0 )); then
#    echo "ERROR: Even the oldest probed cycle is incomplete – abort." >&2
#    exit 3
#fi


# ----------------- Parallel runner ---------------------
dnum=0
runBackground() {
  if [[ -n "${NO_BG:-}" ]]; then
    echo "FG:   fhr=$2"
    downloadStep "$1" "$2"   # <— foreground, show full logs and any errors
  else
    echo "LAUNCH: fhr=$2 (dnum=$dnum -> $((dnum+1)))"
    downloadStep "$1" "$2" &
    ((dnum = dnum + 1))
    if (( dnum % MAX_PAR == 0 )); then
      echo "PAR-WAIT: $MAX_PAR jobs dispatched; waiting…"
      wait
    fi
  fi
}

# ----------------- Config backups per interval ----------
backup_cnf_for_interval() {
  local start="$1" step="$2" end="$3"
  local out="${LOG_DIR}/${AREA}_${RT_DATE_HH}_${start}_${step}_${end}.cnf"
  cp -f -- "$CONFIG_PATH" "$out"
}

# ----------------- Banner ------------------------------
echo "Model Reference Time: $RT_ISO (cycle $RT_DATE_HH)"
echo "Resolution: $RESOLUTION"
echo "Folder: $AREA"
echo "Bounds: left=$LEFT right=$RIGHT top=$TOP bottom=$BOTTOM"
echo "Intervals: ${INTERVALS[*]}"
echo "Destination: $DEST_DIR"
echo "CSV log: $CSV_LOG"
echo "Parallel: $MAX_PAR"

START_TS="$(date -u +%s)"
overall_rc=0

# ----------------- Main loop ---------------------------
for interval in "${INTERVALS[@]}"; do
  log "Interval: $interval"
  # Split "start step end"
  start=$(echo "$interval" | awk '{print $1}')
  step=$(echo "$interval"  | awk '{print $2}')
  end=$(  echo "$interval" | awk '{print $3}')

  if [[ -n "$start" && -n "$step" && -n "$end" ]]; then
    backup_cnf_for_interval "$start" "$step" "$end"
    for fhr in $(seq "$start" "$step" "$end"); do
      if [[ -n "$DRYRUN" ]]; then
        echo -n "$fhr "
      else
        echo "SPAWN: interval='$interval' fhr=$fhr"
        runBackground "$interval" "$fhr"
      fi
    done
    [[ -n "$DRYRUN" ]] && echo ""
  else
    log "Invalid interval: $interval"
  fi
done

[[ -n "$DRYRUN" ]] && exit 0

echo "REMAINING JOBS: $(jobs -pr | wc -l)"

# Wait for remaining jobs
wait || overall_rc=$?

# ----------------- Summary -----------------------------
END_TS="$(date -u +%s)"
TOTAL_ELAPSED=$((END_TS - START_TS))
TOTAL_SIZE_BYTES="$(du -sb "$DEST_DIR" 2>/dev/null | awk '{print $1}')"
TOTAL_SIZE_HR="$(hr_size "${TOTAL_SIZE_BYTES:-0}")"
TOTAL_FILES="$(ls -1 "$DEST_DIR" 2>/dev/null | wc -l)"

echo "---------------------------------------------"
echo "SUMMARY for $AREA @ ${RT_DATE_HH}Z"
echo "Destination : $DEST_DIR"
echo "Files       : $TOTAL_FILES"
echo "Size        : ${TOTAL_SIZE_HR} (${TOTAL_SIZE_BYTES} bytes)"
echo "Elapsed     : ${TOTAL_ELAPSED} s"
echo "CSV log     : $CSV_LOG"
echo "Status      : $([[ $overall_rc -eq 0 ]] && echo SUCCESS || echo WITH ERRORS)"
echo "---------------------------------------------"

exit "$overall_rc"
