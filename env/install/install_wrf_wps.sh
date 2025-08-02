#!/usr/bin/env bash
# install_wrf_wps.sh
# - Loads site toolchain + your WRF/lib_1.0 module
# - Clones WRF into WRF-ohpc if missing, configures (34/1), compiles em_real
# - Verifies wrf.exe / real.exe / ndown.exe
# - Clones WPS into WPS if missing, configures (3), compiles
# - Verifies geogrid.exe / ungrib.exe / metgrid.exe (non-zero size)
# - Writes env/modules/WRF/1.0.lua runtime modulefile (WRF/WPS/Jasper)

set -euo pipefail

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
export J="-j ${JOBS}"   # honored by WRF/WPS compile scripts

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
  # Site toolchain first (consistent with library installer)
  module try-load gnu12/12.2.0  || module load gnu12/12.2.0  || true
  module try-load openmpi4/4.1.5 || module load openmpi4/4.1.5 || true
  module try-load phdf5/1.14.0   || module try-load hdf5/1.14.0 || true

  # Your modulefile (NETCDF/JASPER paths)
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
echo "    JOBS     = ${JOBS}"

# ============================================================
#                      W R F   B U I L D
# ============================================================
echo "==> Ensuring WRF source at ${WRF_DIR}"
just_cloned_wrf=0
if [[ -d "${WRF_DIR}/.git" ]]; then
  echo "    WRF repo already present."
else
  git clone --depth 1 https://github.com/wrf-model/WRF "${WRF_DIR}"
  just_cloned_wrf=1
fi

cd "${WRF_DIR}"

# Clean only if NOT just cloned
if [[ "${just_cloned_wrf}" -eq 0 ]]; then
  echo "==> Cleaning previous WRF build"
  ./clean -a || ./clean || true
fi

# Configure (inputs: 34 then 1)
echo "==> Configuring WRF (34 / 1)"
printf "34\n1\n" | ./configure

# Compile
echo "==> Compiling WRF (em_real) with ${JOBS} jobs"
# Use &> to capture stdout+stderr
./compile em_real &> log.compile

# Verify executables
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

# ============================================================
#                      W P S   B U I L D
# ============================================================
cd "${ROOT_DIR}"

echo "==> Ensuring WPS source at ${WPS_DIR}"
if [[ -d "${WPS_DIR}/.git" ]]; then
  echo "    WPS repo already present."
else
  git clone --depth 1 https://github.com/wrf-model/WPS "${WPS_DIR}"
fi

cd "${WPS_DIR}"

# Clean (safe even if freshly cloned)
./clean || true

# Configure (option 3)
echo "==> Configuring WPS (3)"
printf "3\n" | ./configure

# Compile
echo "==> Compiling WPS with ${JOBS} jobs"
./compile &> log.compile

# Verify WPS executables (non-zero size)
echo "==> Verifying WPS executables"
[[ -s geogrid/src/geogrid.exe ]] || { echo "ERROR: geogrid.exe missing/empty"; exit 1; }
[[ -s ungrib/src/ungrib.exe   ]] || { echo "ERROR: ungrib.exe missing/empty"; exit 1; }
[[ -s metgrid/src/metgrid.exe ]] || { echo "ERROR: metgrid.exe missing/empty"; exit 1; }
echo "    OK: geogrid.exe, ungrib.exe, metgrid.exe found."

# ============================================================
#               W R I T E   R U N T I M E   M O D U L E
# ============================================================
echo "==> Writing modulefile: ${MOD_FILE}"
mkdir -p "${MOD_DIR}"

cat > "${MOD_FILE}" <<'LUA'
-- -*- lua -*-
-- WRF/1.0 environment module for the WRF-ohpc repository

whatis("Name: WRF/1.0.lua")
whatis("Version: 1.0")
whatis("Description: Weather Research and Forecasting (WRF) model; build handled by env/install/install_wrf_wps.sh")

-----------------------------------------------------------------------
-- Locate repo root from this file path: .../env/modules/WRF/1.0.lua
-----------------------------------------------------------------------
local hasMyFileName = (type(myFileName) == "function")
local modfile  = hasMyFileName and myFileName() or pathJoin(myModulePath(), myModuleVersion() or "")
local moddir   = pathJoin(modfile, "..")                       -- .../env/modules/WRF
local proj_root = pathJoin(moddir, "..", "..", "..")           -- repository root

-----------------------------------------------------------------------
-- Dependency stack (OpenHPC hierarchical modules)
-----------------------------------------------------------------------
if not isloaded("gnu12")      then load("gnu12/12.2.0")      end  -- compiler tier
if not isloaded("openmpi4")   then load("openmpi4/4.1.5")   end  -- MPI tier
if not isloaded("netcdf")     then load("netcdf/4.9.0")     end  -- MPI-dependent libs
if not isloaded("netcdf-fortran") then load("netcdf-fortran/4.6.0") end

-----------------------------------------------------------------------
-- Local JasPer (built by install_library.sh under library/grib2)
-----------------------------------------------------------------------
local jasper_root = pathJoin(proj_root, "library", "grib2")
setenv("JASPERINC", pathJoin(jasper_root, "include"))
setenv("JASPERLIB", pathJoin(jasper_root, "lib"))

-----------------------------------------------------------------------
-- WRF + WPS executables and core variables
-----------------------------------------------------------------------
if (mode() == "load") then
  prepend_path("PATH", pathJoin(proj_root, "WRF-ohpc", "main"))
  prepend_path("PATH", pathJoin(proj_root, "WPS"))
  setenv("WRF_DIR", pathJoin(proj_root, "WRF-ohpc"))
  setenv("WPS_DIR", pathJoin(proj_root, "WPS"))

  -- Gentle reminders if something is missing
  local function exists(p)
    local rc = os.execute('[ -e "'..p..'" ] > /dev/null 2>&1')
    return (type(rc) == "number" and rc == 0) or (rc == true)
  end

  local wrfexe  = pathJoin(proj_root, "WRF-ohpc", "main", "wrf.exe")
  local geogrid = pathJoin(proj_root, "WPS", "geogrid", "src", "geogrid.exe")
  if not exists(wrfexe) or not exists(geogrid) then
    LmodMessage("[WRF] Executables not found – run env/install/install_wrf_wps.sh to build the model.")
  end
  if not exists(pathJoin(jasper_root, "lib", "libjasper.a")) then
    LmodMessage("[WRF] Local JasPer not found under "..jasper_root.." – run env/install/install_library.sh")
  end
end
LUA

echo "==> Modulefile written."

echo "==> Done."
echo "WRF path: ${WRF_DIR}"
echo "WPS path: ${WPS_DIR}"
echo "Module : ${MOD_FILE}"
