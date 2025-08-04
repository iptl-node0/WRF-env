#!/usr/bin/env bash
# install_wrf_wps.sh
# - Loads site toolchain + your WRF/lib_1.0 module
# - Clones WRF into WRF-ohpc if missing, configures (34/1), compiles em_real
# - Verifies wrf.exe / real.exe / ndown.exe
# - Clones WPS into WPS if missing, configures (3), compiles
# - Verifies geogrid.exe / ungrib.exe / metgrid.exe (non-zero size)
# - Writes env/modules/WRF/1.0.lua runtime modulefile (WRF/WPS/Jasper)

set -euo pipefail

# === CONFIG: set to 0 to skip WRF build for rapid WPS testing ===
DO_WRF=0  # <-- Set to 0 to skip WRF (for WPS test cycles)

# ---------- Locate repo root ----------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"  # project root
WRF_DIR="${ROOT_DIR}/WRF"
WPS_DIR="${ROOT_DIR}/WPS"
MOD_DIR="${ROOT_DIR}/env/modules/WRF"
MOD_FILE="${MOD_DIR}/1.0.lua"

# ---------- Jobs ----------
detect_jobs() {
  if [[ -n "${WRF_DEP_JOBS:-}" ]]; then echo "${WRF_DEP_JOBS}"; return; fi
  if command -v nproc >/dev/null 2>&1; then nproc
  elif command -v sysctl >/dev/null 2>&1; then sysctl -n hw.ncpu
  else echo 4
  fi
}
JOBS="$(detect_jobs)"
export J="-j ${JOBS}"

# ---------- Helpers ----------
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required tool: $1"; exit 1; }; }
source_lmod_safely() {
  set +u
  if [ -f /etc/profile.d/lmod.sh ]; then
    . /etc/profile.d/lmod.sh
  elif [ -f /usr/share/lmod/lmod/init/bash ]; then
    . /usr/share/lmod/lmod/init/bash
  fi
  set -u
}

# ---------- Tooling checks ----------
for t in git gcc gfortran make; do need "$t"; done

# ---------- Load modules ----------
if ! type module >/dev/null 2>&1; then
  source_lmod_safely
fi
if type module >/dev/null 2>&1; then
  module try-load gnu12/12.2.0  || module load gnu12/12.2.0  || true
  module try-load openmpi4/4.1.5 || module load openmpi4/4.1.5 || true
  module try-load phdf5/1.14.0   || module try-load hdf5/1.14.0 || true
  module use "${ROOT_DIR}/env/modules"
  module load WRF/lib_1.0
else
  echo "ERROR: Lmod/module not available; cannot load WRF/lib_1.0." >&2
  exit 1
fi

# ---------- Sanity: key env from module ----------
: "${NETCDF:?NETCDF not set (module WRF/lib_1.0 should set this)}"
: "${JASPERINC:?JASPERINC not set (module WRF/lib_1.0 should set this)}"
: "${JASPERLIB:?JASPERLIB not set (module WRF/lib_1.0 should set this)}"
need mpicc
need mpif90 || need mpifort

echo "==> Using:"
echo "    ROOT_DIR = ${ROOT_DIR}"
echo "    NETCDF   = ${NETCDF}"
echo "    JASPERINC= ${JASPERINC}"
echo "    JASPERLIB= ${JASPERLIB}"
echo "    LD_LIBRARY_PATH=${JASPERLIB}:${LD_LIBRARY_PATH:-}"
echo "    JOBS     = ${JOBS}"

# ============================================================
#                  W R F   F U N C T I O N
# ============================================================
install_wrf() {
  echo "==> Ensuring WRF source at ${WRF_DIR}"
  just_cloned_wrf=0
  if [[ -d "${WRF_DIR}/.git" ]]; then
    echo "    WRF repo already present."
  else
    git clone --depth 1 https://github.com/wrf-model/WRF "${WRF_DIR}"
    just_cloned_wrf=1
  fi

  cd "${WRF_DIR}"

  if [[ "${just_cloned_wrf}" -eq 0 ]]; then
    echo "==> Cleaning previous WRF build"
    ./clean -a || ./clean || true
  fi

  echo "==> Configuring WRF (34 / 1)"
  printf "34\n1\n" | ./configure

  echo "==> Compiling WRF (em_real) with ${JOBS} jobs"
  ./compile em_real &> log.compile

  echo "==> Verifying WRF executables"
  WRF_MAIN="${WRF_DIR}/main"
  for exe in wrf.exe real.exe ndown.exe; do
    if [[ ! -s "${WRF_MAIN}/${exe}" ]]; then
      echo "ERROR: Missing or empty ${WRF_MAIN}/${exe}"
      echo "       See ${WRF_DIR}/log.compile"
      exit 1
    fi
  done
  echo "    OK: wrf.exe, real.exe, ndown.exe found."
}

# ============================================================
#                  W P S   F U N C T I O N
# ============================================================
install_wps() {
  cd "${ROOT_DIR}"
  echo "==> Ensuring WPS source at ${WPS_DIR}"
  if [[ -d "${WPS_DIR}/.git" ]]; then
    echo "    WPS repo already present."
  else
    git clone --depth 1 https://github.com/wrf-model/WPS "${WPS_DIR}"
  fi

  cd "${WPS_DIR}"

  ./clean || true

  echo "==> Configuring WPS (1)"
  printf "1\n" | ./configure

  # Fix linking order (netcdf-fortran before netcdf)
  perl -0777 -i -pe 's|(WRF_LIB\s*=.*?)(-lnetcdf\b)|$1-lnetcdff $2|s' configure.wps

  echo "==> Compiling WPS with ${JOBS} jobs"
  ./compile &> log.compile

  echo "==> Verifying WPS executables"
  [[ -s geogrid/src/geogrid.exe ]] || { echo "ERROR: geogrid.exe missing/empty"; exit 1; }
  [[ -s ungrib/src/ungrib.exe   ]] || { echo "ERROR: ungrib.exe missing/empty"; exit 1; }
  [[ -s metgrid/src/metgrid.exe ]] || { echo "ERROR: metgrid.exe missing/empty"; exit 1; }
  echo "    OK: geogrid.exe, ungrib.exe, metgrid.exe found."
}

# ============================================================
#          W R I T E   R U N T I M E   M O D U L E
# ============================================================
write_runtime_module() {
  echo "==> Writing modulefile: ${MOD_FILE}"
  mkdir -p "${MOD_DIR}"
  cat > "${MOD_FILE}" <<'LUA'
-- -*- lua -*-
-- WRF/1.0 environment module for this repository

whatis("Name: WRF/1.0.lua")
whatis("Version: 1.0")
whatis("Description: Weather Research and Forecasting (WRF) + WPS runtime env for this repo")

-----------------------------------------------------------------------
-- Robustly determine repo root from modulefile path at load time
-----------------------------------------------------------------------
local modfile = myFileName and myFileName() or debug.getinfo(1, "S").source:sub(2)
local proj_root = modfile:match("(.+)/env/modules/")
if not proj_root then
  LmodError("Cannot determine project root from modulefile path!")
end

-----------------------------------------------------------------------
-- Site toolchain (compiler + MPI). Avoid loading site NetCDF to
-- prevent conflicts with our local netcdf-links.
-----------------------------------------------------------------------
if not isloaded("gnu12")    then load("gnu12/12.2.0")    end
if not isloaded("openmpi4") then load("openmpi4/4.1.5") end
-- HDF5 may be needed at runtime by libnetcdf; try-load only
if not isloaded("phdf5") then load("phdf5/1.14.0") end

-----------------------------------------------------------------------
-- Depend on the local deps module (NETCDF links + grib2/JasPer paths)
-- so we don't redefine them and cause conflicts.
-----------------------------------------------------------------------
if (depends_on) then
  depends_on("WRF/lib_1.0")
end

-- Fallback only if the deps module wasn't present or didn't set them
local function empty(x) return (x == nil) or (x == "") end
if empty(os.getenv("JASPERINC")) or empty(os.getenv("JASPERLIB")) then
  local jasper_root = pathJoin(proj_root, "library", "grib2")
  setenv("JASPERINC", pathJoin(jasper_root, "include"))
  setenv("JASPERLIB", pathJoin(jasper_root, "lib"))
end

-----------------------------------------------------------------------
-- WRF + WPS paths and quality-of-life env
-----------------------------------------------------------------------
local wrf_dir = pathJoin(proj_root, "WRF")
local wps_dir = pathJoin(proj_root, "WPS")

setenv("WRF_DIR", wrf_dir)
setenv("WPS_DIR", wps_dir)

-- Helps when launching from anywhere
prepend_path("PATH", pathJoin(wrf_dir, "main"))
prepend_path("PATH", wps_dir)

-----------------------------------------------------------------------
-- Friendly checks on load
-----------------------------------------------------------------------
if (mode() == "load") then
  local function exists(p)
    local rc = os.execute('[ -e "'..p..'" ] > /dev/null 2>&1')
    return (type(rc) == "number" and rc == 0) or (rc == true)
  end

  local wrfexe   = pathJoin(wrf_dir, "main", "wrf.exe")
  local geogrid  = pathJoin(wps_dir, "geogrid", "src", "geogrid.exe")

  if not exists(wrfexe) or not exists(geogrid) then
    LmodMessage("[WRF] Executables not found – run env/install/install_wrf_wps.sh to build the model.")
  end

  local jasperlib = os.getenv("JASPERLIB") or ""
  if jasperlib == "" or not exists(pathJoin(jasperlib, "libjasper.a")) and not exists(pathJoin(jasperlib, "libjasper.so")) then
    LmodMessage("[WRF] JasPer libs not found – ensure library/grib2 was built or load WRF/lib_1.0.")
  end
end
LUA

  echo "==> Modulefile written."
}

# ============================================================
#                MAIN DRIVER
# ============================================================
if [[ "${DO_WRF}" -eq 1 ]]; then
  install_wrf
else
  echo "==> Skipping WRF build (DO_WRF=0)"
fi

install_wps
write_runtime_module

echo "==> Done."
echo "WRF path: ${WRF_DIR}"
echo "WPS path: ${WPS_DIR}"
echo "Module : ${MOD_FILE}"
