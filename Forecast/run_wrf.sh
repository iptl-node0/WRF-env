#!/bin/bash

# Runs WPS to generate input files for WRF

# explanation references:
# https://www2.mmm.ucar.edu/wrf/OnLineTutorial/compilation_tutorial.php#STEP7
# https://www2.mmm.ucar.edu/wrf/users/namelist_best_prac_wps.html

# GFS data sources: https://www.nco.ncep.noaa.gov/pmb/products/gfs/
# 		    https://nomads.ncep.noaa.gov/

###############################################################################
##  Configuration loader – pulls values from gns.cnf --------------------------
##  Order of precedence for each var:                                        ##
##    1) already exported in the environment                                 ##
##    2) value read from gfs.cnf (bash syntax)                               ##
##    3) hard‑coded fallback below                                           ##
###############################################################################

#--- load module --------------------------------------------------------------

set -euo pipefail

initial_dir=$(pwd)
start_time=$(date +%s)

# --- enable Lmod if not already available
source_lmod_safely() {
  set +u
  if [ -f /etc/profile.d/lmod.sh ]; then
    . /etc/profile.d/lmod.sh
  elif [ -f /usr/share/lmod/lmod/init/bash ]; then
    . /usr/share/lmod/lmod/init/bash
  fi
  set -u
}
type module >/dev/null 2>&1 || source_lmod_safely

# --- load repo runtime module (auto-loads deps via depends_on)
if type module >/dev/null 2>&1; then
  # Derive repo root from this script location
  SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
  ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
  module use "${ROOT_DIR}/env/modules"
  module load WRF/1.0
fi

#--- locate config file -------------------------------------------------------
CFG_FILE=${1:-$(dirname "${BASH_SOURCE[0]}")/gfs.cnf}
if [[ ! -r "$CFG_FILE" ]]; then
  echo "ERROR: config file not found or not readable: $CFG_FILE" >&2
  exit 2
fi
# shellcheck source=/dev/null
. "$CFG_FILE"

#--- paths that almost never change (provide defaults) ------------------------
# Prefer module-provided paths; allow override via env or gfs.cnf
: "${WPS_DIR:=${WPS_DIR:-}}"
: "${WRF_DIR:=${WRF_DIR:-}}"
: "${GEOG_DATA_PATH:=/mnt/node0-bulk1/MET/GEOG/WPS_GEOG}"

# If still empty (module not loaded), fall back relative to repo layout
if [[ -z "${WPS_DIR}" || -z "${WRF_DIR}" ]]; then
  SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
  ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
  : "${WPS_DIR:=${ROOT_DIR}/WPS}"
  : "${WRF_DIR:=${ROOT_DIR}/WRF/test/em_real}"
fi

# Pull extra values from gfs.cnf -----------------------------------
: "${FOLDER_NAME:=${CASE_NAME:-unknown_case}}"
: "${WRF_DEST:=/mnt/node0-bulk1/MET}"
: "${CASE_ROOT:=/mnt/node0-bulk1/WRF_CASES}"
: "${INTERVAL_SEC:?}"      # already in gfs.cnf
: "${RUN_DAYS:?}"
: "${START_DATE:?}"
: "${END_DATE:?}"

# components are already in the file – assert they exist
: "${START_YEAR:?}${START_MONTH:?}${START_DAY:?}${START_HOUR:?}"
: "${END_YEAR:?}${END_MONTH:?}${END_DAY:?}${END_HOUR:?}"

# Respect override of GEOG_DATA_PATH passed via gfs.cnf
[ -n "${GEOG_DATA_PATH:-}" ] && GEOG_DATA_PATH="${GEOG_DATA_PATH//\"/}"

# centre / radius supplied by generate_square_corners.py → gfs.cnf
: "${CENTER_LAT:=0}"
: "${CENTER_LON:=0}"
: "${RADIUS_KM:=900}"              # default half‑side of 900 km (= 1800 km square)
DOMAIN_SIZE=$(printf "%.0f" "$(bc -l <<< "2 * ${RADIUS_KM}")")   # km

# interval seconds
INTERVAL=$INTERVAL_SEC

# cycle picked by the downloader (10‑digit UTC string), e.g. 2025073100
: "${CYCLE:=latest}"
if [[ "$CYCLE" == "latest" ]]; then
  CYCLE=$(date -u -d '-3 hours' +%Y%m%d%H | sed 's/$/00/')   # round to 6‑hour snap later
fi

# resolution 0p25→~27 km, 0p50→~55 km, 1p00→~111 km
case "${RESOLUTION:-0p25}" in
  0p25) DATA_RESOLUTION=27 ;;
  0p50) DATA_RESOLUTION=55 ;;
  1p00|1p0|1.0) DATA_RESOLUTION=111 ;;
  *)     DATA_RESOLUTION=27 ;;
esac
GRID1_RESOLUTION=$(( DATA_RESOLUTION * 1000 / 3 ))   # 1/3 scaling rule of thumb
GRID2_RESOLUTION=$(( GRID1_RESOLUTION / 3 ))

# grid sizes / points
DOWNSCALING_FACTOR=0.67
GRID1_SIZE=$(printf "%.0f" "$(bc -l <<< "${DOMAIN_SIZE} * ${DOWNSCALING_FACTOR}")")
GRID2_SIZE=$(printf "%.0f" "$(bc -l <<< "${GRID1_SIZE} * ${DOWNSCALING_FACTOR}")")
GRID1_POINTS=$(( GRID1_SIZE * 1000 / GRID1_RESOLUTION ))
GRID2_POINTS=$(( GRID2_SIZE * 1000 / GRID2_RESOLUTION ))

# truelats for Lambert (≈ ±⅓ of domain half‑span)
deg_per_km=$(bc -l <<< "1 / 111.32")
lat_span_deg=$(bc -l <<< "${DOMAIN_SIZE} * ${deg_per_km}")
delta=$(bc -l <<< "${lat_span_deg} / 3")
truelat1=$(printf "%.4f" "$(bc -l <<< "${CENTER_LAT} - ${delta}")")
truelat2=$(printf "%.4f" "$(bc -l <<< "${CENTER_LAT} + ${delta}")")

#--- data / case paths --------------------------------------------------------
WRF_MET_ROOT="${WRF_DEST}/${FOLDER_NAME}"
GFS_DATA_PATH="${WRF_MET_ROOT}/${CYCLE}"
GFS_PREFIX="gfs.t${CYCLE:8:2}z.pgrb2.${RESOLUTION:-0p25}"

CASE_NAME=${CASE_NAME:-"${FOLDER_NAME}_${CYCLE}_${DOMAIN_SIZE}km_${GRID1_RESOLUTION}m"}
CASE_PATH="${CASE_ROOT}/${CASE_NAME}"
CASE_INPUTS_PATH="${CASE_PATH}/inputs"
CASE_INPUTS=$(basename "$CASE_INPUTS_PATH")


export WPS_DIR WRF_DIR GEOG_DATA_PATH \
       GFS_DATA_PATH GFS_PREFIX \
       CASE_NAME CASE_PATH CASE_INPUTS CASE_INPUTS_PATH \
       START_DATE END_DATE INTERVAL \
       DOMAIN_SIZE CENTER_LAT CENTER_LON RUN_DAYS \
       START_YEAR START_MONTH START_DAY START_HOUR \
       END_YEAR END_MONTH END_DAY END_HOUR \
       DATA_RESOLUTION GRID1_RESOLUTION GRID2_RESOLUTION \
       GRID1_SIZE GRID2_SIZE GRID1_POINTS GRID2_POINTS \
       truelat1 truelat2
###############################################################################
## End of configuration loader -----------------------------------------------
###############################################################################

# --- util: create (or overwrite) directory non‑interactively ----
handle_directory() {
    local dir_path=$1
    if [ -d "$dir_path" ] && (( ${FORCE_NEW_CASE:-1} )); then
        rm -rf "$dir_path"
    fi
    mkdir -p "$dir_path"
}

# Handle CASE_PATH
handle_directory "$CASE_PATH"
handle_directory "$CASE_INPUTS_PATH"

# Check if GEOG_DATA_PATH exists
if [ ! -d "$GEOG_DATA_PATH" ]; then
    echo "Error: Geography static data path does not exist."
    exit 1
fi

# Check if GFS_DATA_PATH exists
if [ ! -d "$GFS_DATA_PATH" ]; then
    echo "Error: GFS data path does not exist."
    exit 1
fi

echo "GEOG and GFS paths exist."

# Change to WPS directory
cd $WPS_DIR

# Check command success
if [ $? -ne 0 ]; then
    echo "cd to WPS failed to execute successfully."
    exit 1
fi

# Cleanup WPS directory
rm -f geo_em*
rm -f met_em*
rm -f GRIBFILE*
rm -f ./*gdas1*
rm -f log.WPS
rm -f log.geogrid
rm -f log.ungrib
rm -f log.metgrid

echo "WPS cleanup complete."

# Generate namelist.wps file
cat <<EOL > namelist.wps
&share
 wrf_core = 'ARW',                ! Which dynamical core the input data are being prepared for
 max_dom = 1,                     ! Total number of domains including parent domain
 start_date = '$START_DATE', ! Beginning date and time of simulation
 end_date   = '$END_DATE', ! Ending date and time of simulation
 interval_seconds = $INTERVAL         ! Temporal interval for input data availability
/

&geogrid
 parent_id         = 1,                  ! Domain number ID of each domain's parent
 parent_grid_ratio = 1,                  ! Nesting ratio relative to domain's parent
 i_parent_start    = 1,                  ! x coordinate of lower left corner of nest in parent domain
 j_parent_start    = 1,                  ! y coordinate of lower left corner of nest in parent domain
 e_we              = $GRID1_POINTS,                ! West-east dimensions in grid squares, minimum 100
 e_sn              = $GRID1_POINTS,                ! South-north dimensions in grid squares, minimum 100
 geog_data_res     = 'default',          ! Resolution of source data for interpolating static terrestrial data
 dx                = $GRID1_RESOLUTION,              ! Grid distance in x direction in meters
 dy                = $GRID1_RESOLUTION,              ! Grid distance in y direction in meters
 map_proj          = 'lambert',          ! Projection type
 ref_lat           = $CENTER_LAT,              ! Latitude of known location in domain, center of coarse domain
 ref_lon           = $CENTER_LON,             ! Longitude of known location in domain, center of coarse domain
 truelat1          = $truelat1,               ! First true latitude for lambert projection
 truelat2          = $truelat2,               ! 
 stand_lon         = $CENTER_LON,              ! Longitude parallel with y-axis
 
 geog_data_path    = '$GEOG_DATA_PATH'   ! Path where static geographical data is stored
/

&ungrib
 out_format = 'WPS',         ! Format of intermediate file
 prefix     = '$GFS_PREFIX',        ! Prefix for intermediate files
/

&metgrid
 fg_name    = '$GFS_PREFIX'         ! Prefix used when intermediate files were created
/
EOL

# Copy run_WPS.sh and WPS namelist file into inputs folder
cp ./namelist.wps "$CASE_INPUTS_PATH"

###############################################################################
# W P S   – geogrid, link_grib, ungrib, metgrid (robust wrapper)
###############################################################################

# --- verify the executables are present & decide if they are MPI builds ------
for exe in geogrid.exe ungrib.exe metgrid.exe; do
    if [ ! -x "${exe}" ]; then
        echo "ERROR: ${exe} not found or not executable in $WPS_DIR" >&2
        exit 2
    fi
done

#is_mpi() { strings "$1" | grep -qiE 'mpi|openmpi|mpich'; }
#[ -z "${MPIRUN_CMD:-}" ] && MPIRUN_CMD="mpirun"

#if is_mpi geogrid.exe;  then GEOGRID_RUN=( $MPIRUN_CMD ./geogrid.exe );  else GEOGRID_RUN=( ./geogrid.exe );  fi
# ungrib is always serial
#if is_mpi metgrid.exe;  then METGRID_RUN=( $MPIRUN_CMD ./metgrid.exe );  else METGRID_RUN=( ./metgrid.exe );  fi

# geogrid with >1 rank corrupts geo_em.* when only one domain is used.
# Force single‑rank run even if the binary is dmpar.
GEOGRID_RUN=( ./geogrid.exe )

# ungrib is always serial; metgrid can be mpi but 1 rank is safer here
METGRID_RUN=( ./metgrid.exe )

unset MPIRUN_CMD

# --- helper to execute a step, keep log, honour -e ---------------------------
run_wps_step() {
    local label=$1; shift
    local logfile="log.${label}"
    echo "Running ${label}."
    local t0=$(date +%s)

    set +e
    "$@" >& "${logfile}"
    local rc=$?
    set -e

    if [ ${rc} -ne 0 ]; then
        echo "${label} failed (rc=${rc})." | tee -a log.WPS
        exit 1
    fi
    local dt=$(( $(date +%s) - t0 ))
    echo "${label} time: ${dt}" | tee -a log.WPS
    eval "${label}_time=${dt}"
}

# --------------------- 1.  geogrid -------------------------------------------
run_wps_step geogrid   "${GEOGRID_RUN[@]}"

# --------------------- 2.  link_grib + Vtable --------------------------------
echo "Running link_grib."
./link_grib.csh "${GFS_DATA_PATH}" || {
    echo "link_grib failed." | tee -a log.WPS
    exit 1
}

echo "Linking Vtable."
ln -sf ungrib/Variable_Tables/Vtable.GFS Vtable || {
    echo "Vtable link failed." | tee -a log.WPS
    exit 1
}

# --------------------- 3.  ungrib --------------------------------------------
run_wps_step ungrib    ./ungrib.exe

# --------------------- 4.  metgrid -------------------------------------------
run_wps_step metgrid   "${METGRID_RUN[@]}"

echo "WPS processes completed!" | tee -a log.WPS

# --------------------- 5.  runtime summary -----------------------------------
total_time=$(( $(date +%s) - start_time ))
echo "Total WPS runtime: ${total_time} s  (geogrid: ${geogrid_time:-NA} | ungrib: ${ungrib_time:-NA} | metgrid: ${metgrid_time:-NA})" | tee -a log.WPS

# Copy namelist & logs into case‑inputs folder
wps_log_files=( namelist.wps log.WPS log.geogrid log.ungrib log.metgrid )
for f in "${wps_log_files[@]}"; do
    [ -f "$f" ] && cp "$f" "${CASE_INPUTS_PATH}"
done
###############################################################################
# end of WPS wrapper
###############################################################################


################
# Run WRF Real #
################

# Navigate to WRF project directory in /test/em_real/
cd "${WRF_DIR}"

# Check command success
if [ $? -ne 0 ]; then
    echo "cd to WRF failed to execute successfully."
    exit 1
fi

# Cleanup WRF/test/em_real/ directory
rm -f met_em*
rm -f wrfout*
rm -f wrfrst*
rm -f log.WRF
rm -f log.real
rm -f log.wrfexe

# Link met_em* paths from WPS directory
# ln -sf ../../../WPS/met_em* .
ln -sf "$WPS_DIR"/met_em* .

# Generate namelist.input file
cat <<EOL > namelist.input
&time_control
 run_days                            = $RUN_DAYS,
 run_hours                           = 0,
 run_minutes                         = 0,
 run_seconds                         = 0,
 start_year                          = $START_YEAR,
 start_month                         = $START_MONTH,
 start_day                           = $START_DAY,
 start_hour                          = $START_HOUR,
 end_year                            = $END_YEAR,
 end_month                           = $END_MONTH,
 end_day                             = $END_DAY,
 end_hour                            = $END_HOUR,
 interval_seconds                    = $INTERVAL,
 input_from_file                     = .true.,
 history_interval                    = 60,
 frames_per_outfile                  = 1,
 restart                             = .false.,
 restart_interval                    = $INTERVAL,
 io_form_history                     = 2
 io_form_restart                     = 2
 io_form_input                       = 2
 io_form_boundary                    = 2
 /

 &domains
 time_step                           = 45,
 time_step_fract_num                 = 0,
 time_step_fract_den                 = 1,
 max_dom                             = 1,
 s_we                                = 1,
 e_we                                = $GRID1_POINTS,
 s_sn                                = 1,
 e_sn                                = $GRID1_POINTS,
 s_vert                              = 1, 
 e_vert                              = 45,
 dzstretch_s                         = 1.1
 p_top_requested                     = 5000,
 num_metgrid_levels                  = 34,
 num_metgrid_soil_levels             = 4,
 dx                                  = $GRID1_RESOLUTION,
 dy                                  = $GRID1_RESOLUTION,
 grid_id                             = 1,
 parent_id                           = 0,
 i_parent_start                      = 1,
 j_parent_start                      = 1,
 parent_grid_ratio                   = 1,
 parent_time_step_ratio              = 1,
 feedback                            = 0,
 smooth_option                       = 0
 /

 &physics
 physics_suite                       = 'CONUS',
 mp_physics                          = -1,
 cu_physics                          = -1,
 ra_lw_physics                       = -1,
 ra_sw_physics                       = -1,
 bl_pbl_physics                      = -1,
 sf_sfclay_physics                   = -1,
 sf_surface_physics                  = -1,
 radt                                = 9,
 bldt                                = 0,
 cudt                                = 0,
 icloud                              = 1,
 num_land_cat                        = 21,
 sf_urban_physics                    = 0
 fractional_seaice                   = 1
 /

 &fdda
 /

 &dynamics
 hybrid_opt                          = 2, 
 w_damping                           = 1,
 diff_opt                            = 2,
 km_opt                              = 4,
 diff_6th_opt                        = 0,
 diff_6th_factor                     = 0.12,
 base_temp                           = 290.
 damp_opt                            = 3,
 zdamp                               = 5000.,
 dampcoef                            = 0.2,
 khdif                               = 0,
 kvdif                               = 0,
 non_hydrostatic                     = .true.,
 moist_adv_opt                       = 1,
 scalar_adv_opt                      = 1,
 gwd_opt                             = 1,
 /

 &bdy_control
 spec_bdy_width                      = 5,
 specified                           = .true.
 /

 &grib2
 /

 &namelist_quilt
 nio_tasks_per_group = 0,
 nio_groups = 1,
 /
EOL

# Environment variables
wrf_start_time=$(date +%s)

# Run real.exe program
mpirun ./real.exe >> log.real

# Check command success
if [ $? -ne 0 ]; then
    echo "Real failed to execute successfully."
    echo "Real failed to execute successfully." >> log.WRF
    exit 1
fi

# Log time
real_time=$(($(date +%s) - wrf_start_time))
echo "real.exe time: $real_time" >> log.WRF

# Run wrf.exe program
mpirun ./wrf.exe >> log.wrfexe

# Check command success
if [ $? -ne 0 ]; then
    echo "WRF failed to execute successfully."
    echo "WRF failed to execute successfully." >> log.WRF
    exit 1
fi

# Log time
wrf_time=$(($(date +%s) - wrf_start_time - real_time))
echo "wrf.exe time: $wrf_time" >> log.WRF


# Output bash script runtimes
echo "WRF processes completed!"
echo "WRF processes completed!" >> log.WRF

wrf_model_time=$(($(date +%s) - wrf_start_time))
echo "Total WRF model runtime: $wrf_model_time seconds. Real: $real_time sec. WRF: $wrf_time sec."
echo "Total WRF model runtime: $wrf_model_time seconds. Real: $real_time sec. WRF: $wrf_time sec." >> log.WRF

# Copy log files to case inputs directory

wrf_log_files=("namelist.input" "log.real" "log.wrfexe")

for file in "${wrf_log_files[@]}"; do
    if [ ! -f "$file" ]; then
        echo "Error: Missing file $file" >> log.WRF
        exit 1
    else
        echo "Copying $file to ${CASE_INPUTS_PATH}" >> log.WRF
        cp "$file" "${CASE_INPUTS_PATH}"
    fi
done

# Move output files to CASE_PATH for use
echo "Moving wrfout* files to ${CASE_PATH}."
echo "Moving wrfout* files to ${CASE_PATH}." >> log.WRF
mv wrfout* "${CASE_PATH}"

# Check command success
if [ $? -ne 0 ]; then
    echo "Move wrfout* files failed to execute successfully."
    echo "Move wrfout* files failed to execute successfully." >> log.WRF
    exit 1
fi

# Leave log.WRF for last to copy files to case inputs directory

WRF_log=("log.WRF")

for file in "${WRF_log[@]}"; do
    if [ ! -f "$file" ]; then
        echo "Error: Missing file $file"
        exit 1
    else
        echo "Copying $file to ${CASE_INPUTS_PATH}"
        cp "$file" "${CASE_INPUTS_PATH}"
    fi
done

echo "Done running WRF!"
exit 0
