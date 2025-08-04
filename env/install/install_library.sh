#!/usr/bin/env bash
#
# install_library.sh
# WRF dependency installer (excluding building NetCDF/NetCDF-Fortran).
# Builds now: zlib, libpng, jasper
# Optional knobs kept for future: --build-mpich, --with-hdf5
# Creates library layout and an Lmod modulefile.
# Links existing NetCDF C/Fortran into library/netcdf-links (from modules or paths).
#
# Typical usage (from repo root or anywhere):
#   env/install/install_library.sh \
#     --netcdf  /opt/.../netcdf/4.9.0 \
#     --netcdff /opt/.../netcdf-fortran/4.6.0
#
# Options:
#   --prefix DIR           Install prefix (default: <repo-root>/library)
#   --jobs N               Parallel build jobs (default: autodetect or $WRF_DEP_JOBS)
#   --with-hdf5            Also build HDF5 into $PREFIX/hdf5 (optional; default off)
#   --build-mpich          Also build MPICH into $PREFIX/mpich (optional; default off)
#   --module-name NAME     Lmod module name (default: WRF)
#   --module-version VER   Lmod module version (default: lib_1.0)
#   --netcdf DIR           Existing NetCDF-C root to link (optional; auto from modules)
#   --netcdff DIR          Existing NetCDF-Fortran root to link (optional; auto from modules)
#
set -euo pipefail

# ---------- Resolve script, root, and defaults ----------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"          # repo root holding library/, WPS/, WRF-ohpc/
DEFAULT_PREFIX="${ROOT_DIR}/library"

PREFIX="${DEFAULT_PREFIX}"
MODULE_NAME="WRF"
MODULE_VERSION="lib_1.0"
WITH_HDF5="0"         # default off (use site phdf5)
BUILD_MPICH="0"       # default off (use site OpenMPI)
NETCDF_SRC=""
NETCDFF_SRC=""

detect_jobs() {
  if [[ -n "${WRF_DEP_JOBS:-}" ]]; then echo "${WRF_DEP_JOBS}"; return; fi
  if command -v nproc >/dev/null 2>&1; then nproc
  elif command -v sysctl >/dev/null 2>&1; then sysctl -n hw.ncpu
  else echo 4
  fi
}
JOBS="$(detect_jobs)"

usage() {
  sed -n '1,120p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

# ---------- Parse args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)          PREFIX="$2"; shift 2 ;;
    --jobs)            JOBS="$2"; shift 2 ;;
    --with-hdf5)       WITH_HDF5="1"; shift ;;
    --build-mpich)     BUILD_MPICH="1"; shift ;;
    --module-name)     MODULE_NAME="$2"; shift 2 ;;
    --module-version)  MODULE_VERSION="$2"; shift 2 ;;
    --netcdf)          NETCDF_SRC="$2"; shift 2 ;;
    --netcdff)         NETCDFF_SRC="$2"; shift 2 ;;
    -h|--help)         usage ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ---------- Ensure structure ----------
mkdir -p "${PREFIX}"/{src,grib2,netcdf-links}
mkdir -p "${PREFIX}/grib2"/{bin,include,lib}

# ---------- Common helpers ----------
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required tool: $1"; exit 1; }; }

source_lmod_safely() {
  # Avoid nounset explosions inside vendor scripts (e.g., SLURM_NODELIST)
  set +u
  if [ -f /etc/profile.d/lmod.sh ]; then
    . /etc/profile.d/lmod.sh
  elif [ -f /usr/share/lmod/lmod/init/bash ]; then
    . /usr/share/lmod/lmod/init/bash
  fi
  set -u
}

# ---------- Bootstrap modules/toolchains ----------
bootstrap_compilers() {
  if ! type module >/dev/null 2>&1; then
    source_lmod_safely
  fi
  if type module >/dev/null 2>&1; then
    module try-load gnu12/12.2.0  || module load gnu12/12.2.0  || true
    module try-load openmpi4/4.1.5 || module load openmpi4/4.1.5 || true
    # parallel HDF5; fallback to hdf5 if phdf5 module name isn't present
    module try-load phdf5/1.14.0 || module load phdf5/1.14.0 || true
  fi
}
bootstrap_compilers

# ---------- Sanity checks ----------
for tool in curl tar make gcc g++ gfortran; do need "$tool"; done
for tool in mpicc h5pcc; do need "$tool"; done

MPI_BIN="$(dirname "$(command -v mpicc)")"
HDF5_BIN="$(dirname "$(command -v h5pcc)")"
export MPI_BIN HDF5_BIN

echo "==> Script directory : ${SCRIPT_DIR}"
echo "==> Project root     : ${ROOT_DIR}"
echo "==> Install prefix   : ${PREFIX}"
echo "==> Build jobs       : ${JOBS}"
echo "==> MPI mode         : OpenMPI (site modules)"
echo "==> MPI_BIN          : ${MPI_BIN}"
echo "==> HDF5_BIN         : ${HDF5_BIN}"

# Sanity: verify parallel HDF5
if h5pcc -showconfig 2>/dev/null | grep -qi 'Parallel HDF5: *yes'; then
  echo "==> HDF5 (parallel)  : OK"
else
  echo "WARNING: h5pcc does not report Parallel HDF5=YES; check your modules (phdf5)." >&2
fi

# ---------- Versions (for local builds if enabled) ----------
ZLIB_VER="1.2.11"
LIBPNG_VER="1.2.50"
JASPER_VER="1.900.1"
MPICH_VER="3.0.4"
HDF5_VER="1_10_5"

# ---------- Fetch helper ----------
fetch() {
  local url="$1" out="${2:-}"
  if [[ -n "$out" ]]; then
    [[ -f "$out" ]] || curl -fsSL -o "$out" "$url"
  else
    curl -fsSL -O "$url"
  fi
}

# ---------- Builders ----------
build_zlib() {
  local tar="zlib-${ZLIB_VER}.tar.gz"
  pushd "${PREFIX}/src" >/dev/null
    fetch "https://www2.mmm.ucar.edu/wrf/OnLineTutorial/compile_tutorial/tar_files/${tar}" "$tar"
    rm -rf "zlib-${ZLIB_VER}"
    tar xzf "$tar"
    pushd "zlib-${ZLIB_VER}" >/dev/null
      CC="${CC:-gcc}" ./configure --prefix="${PREFIX}/grib2"
      make -j "${JOBS}"
      make install
    popd >/dev/null
    rm -rf "zlib-${ZLIB_VER}" "$tar"
  popd >/dev/null
}

build_libpng() {
  local tar="libpng-${LIBPNG_VER}.tar.gz"
  pushd "${PREFIX}/src" >/dev/null
    fetch "https://www2.mmm.ucar.edu/wrf/OnLineTutorial/compile_tutorial/tar_files/${tar}" "$tar"
    rm -rf "libpng-${LIBPNG_VER}"
    tar xzf "$tar"
    pushd "libpng-${LIBPNG_VER}" >/dev/null
      CPPFLAGS="-I${PREFIX}/grib2/include" \
      LDFLAGS="-L${PREFIX}/grib2/lib" \
      CC="${CC:-gcc}" ./configure --prefix="${PREFIX}/grib2"
      make -j "${JOBS}"
      make install
    popd >/dev/null
    rm -rf "libpng-${LIBPNG_VER}" "$tar"
  popd >/dev/null
}

build_jasper() {
  local tar="jasper-${JASPER_VER}.tar.gz"
  pushd "${PREFIX}/src" >/dev/null
    fetch "https://www2.mmm.ucar.edu/wrf/OnLineTutorial/compile_tutorial/tar_files/${tar}" "$tar"
    rm -rf "jasper-${JASPER_VER}"
    tar xzf "$tar"
    pushd "jasper-${JASPER_VER}" >/dev/null
      CPPFLAGS="-I${PREFIX}/grib2/include -fcommon" \
      LDFLAGS="-L${PREFIX}/grib2/lib" \
      CC="${CC:-gcc}" CXX="${CXX:-g++}" \
      ./configure --prefix="${PREFIX}/grib2"
      make -j "${JOBS}"
      make install
    popd >/dev/null
    rm -rf "._jasper-${JASPER_VER}" "jasper-${JASPER_VER}" "$tar"
  popd >/dev/null
}

build_mpich() {
  local tar="mpich-${MPICH_VER}.tar.gz"
  pushd "${PREFIX}/src" >/dev/null
    fetch "https://www2.mmm.ucar.edu/wrf/OnLineTutorial/compile_tutorial/tar_files/${tar}" "$tar"
    rm -rf "mpich-${MPICH_VER}"
    tar xf "$tar"
    pushd "mpich-${MPICH_VER}" >/dev/null
      CC="${CC:-gcc}" CXX="${CXX:-g++}" \
      FC="${FC:-gfortran}" F77="${F77:-gfortran}" \
      FFLAGS="${FFLAGS:- -O2 -fallow-argument-mismatch}" \
      FCFLAGS="${FCFLAGS:- -O2 -fallow-argument-mismatch}" \
      ./configure --prefix="${PREFIX}/mpich"
      make -j "${JOBS}"
      make install
    popd >/dev/null
    rm -rf "mpich-${MPICH_VER}" "$tar"
  popd >/dev/null
}

build_hdf5_optional() {
  [[ "${WITH_HDF5}" == "1" ]] || return 0
  local tar="hdf5-${HDF5_VER}.tar.gz"
  pushd "${PREFIX}/src" >/dev/null
    fetch "https://github.com/HDFGroup/hdf5/archive/${tar}" "$tar"
    rm -rf "hdf5-hdf5-${HDF5_VER}"
    tar xzf "$tar"
    pushd "hdf5-hdf5-${HDF5_VER}" >/dev/null
      CC="${CC:-gcc}" FC="${FC:-gfortran}" \
      ./configure \
        --prefix="${PREFIX}/hdf5" \
        --with-zlib="${PREFIX}/grib2" \
        --enable-fortran \
        --enable-shared
      make -j "${JOBS}"
      make install
    popd >/dev/null
    rm -rf "hdf5-hdf5-${HDF5_VER}" "$tar"
  popd >/dev/null
}

# ---- NetCDF linking (robust: mirrors directories, links files) ----
link_netcdf_trees() {
  local nc_src="$1" ncf_src="$2" target="${PREFIX}/netcdf-links"
  [[ -z "$nc_src" && -z "$ncf_src" ]] && { echo "No NetCDF sources provided; skipping link stage."; return 0; }
  echo "Linking NetCDF trees into: ${target}"
  mkdir -p "${target}"/{bin,include,lib}

  # Mirror a subtree (bin/include/lib) and symlink files recursively.
  mirror_and_link() {
    local src_root="$1" subdir="$2"
    local src="${src_root}/${subdir}"
    local dst="${target}/${subdir}"
    [[ -d "$src" ]] || return 0

    # Create all directories first
    # shellcheck disable=SC2044
    for d in $(find "$src" -type d -print); do
      local rel="${d#${src_root}/$subdir}"
      mkdir -p "${dst}${rel}"
    done
    # Link all files (overwrite if exist)
    # shellcheck disable=SC2044
    for f in $(find "$src" -type f -print); do
      local rel="${f#${src_root}/$subdir}"
      ln -sfn "$f" "${dst}${rel}"
    done
  }

  for root in "$nc_src" "$ncf_src"; do
    [[ -n "$root" ]] || continue
    mirror_and_link "$root" bin
    mirror_and_link "$root" include
    mirror_and_link "$root" lib
  done

  # Ensure versionless .so symlinks exist for linker compatibility
  for libbase in netcdf netcdff; do
    libdir="${target}/lib"
    found_versioned=""
    # Find versioned .so file (libnetcdf.so.X.Y.Z)
    if [ -d "$libdir" ]; then
      for f in "$libdir"/lib${libbase}.so.*; do
        if [ -f "$f" ]; then
          found_versioned="$f"
          break
        fi
      done
      
      # Create/replace symlink if needed
      #if [ -n "$found_versioned" ] && [ ! -L "$libdir/lib${libbase}.so" ]; then
      #  ln -sf "$(basename "$found_versioned")" "$libdir/lib${libbase}.so"
      #fi
      
      # in link_netcdf_trees(), replace the symlink-if-not-L test with unconditional update:
      if [ -n "$found_versioned" ]; then
        ln -sfn "$(basename "$found_versioned")" "$libdir/lib${libbase}.so"
      fi
    fi
  done

  echo "Done. Export NETCDF='${target}' to use these in builds."
}

# ---------- Detect & link NetCDF (after builds) ----------
detect_and_link_netcdf() {
  local nc_src="${NETCDF_SRC:-}"
  local ncf_src="${NETCDFF_SRC:-}"

  if ! type module >/dev/null 2>&1; then
    source_lmod_safely
  fi
  if type module >/dev/null 2>&1; then
    module try-load netcdf/4.9.0         || module load netcdf/4.9.0         || true
    module try-load netcdf-fortran/4.6.0 || module load netcdf-fortran/4.6.0 || true
  fi

  if command -v nc-config  >/dev/null 2>&1; then nc_src="${nc_src:-$(nc-config  --prefix)}"; fi
  if command -v nf-config  >/dev/null 2>&1; then ncf_src="${ncf_src:-$(nf-config --prefix)}"; fi

  if [ -n "${nc_src}" ] && [ -n "${ncf_src}" ]; then
    echo "Detected NetCDF prefixes:"
    echo "  C:        ${nc_src}"
    echo "  Fortran:  ${ncf_src}"
    if command -v nc-config >/dev/null 2>&1; then
      if nc-config --has-parallel4 2>/dev/null | grep -qi '^yes$'; then
        if nc-config --libs 2>/dev/null | grep -qi 'openmpi'; then
          echo "==> NetCDF parallel/OpenMPI: OK"
        else
          echo "WARNING: NetCDF is parallel but not clearly OpenMPI-linked; verify module stack." >&2
        fi
      else
        echo "WARNING: NetCDF appears serial; fine for WRF, but won’t use parallel I/O." >&2
      fi
    fi
    link_netcdf_trees "${nc_src}" "${ncf_src}"
  else
    echo "NetCDF not linked (no sources found)."
    echo "Pass --netcdf/--netcdff, or ensure modules provide nc-config/nf-config."
  fi
}

# ---- Modulefile writer (no MPI edits; uses site modules) ----
write_modulefile() {
  local mod_root="${ROOT_DIR}/env/modules/${MODULE_NAME}"
  local mod_path="${mod_root}/${MODULE_VERSION}.lua"
  mkdir -p "${mod_root}"

  local NETCDF_LINKS="${PREFIX}/netcdf-links"
  local JASPERLIB="${PREFIX}/grib2/lib"
  local JASPERINC="${PREFIX}/grib2/include"
  local GRIB2_LIB="${PREFIX}/grib2/lib"

  cat > "${mod_path}" <<'LUA'
-- Auto-generated modulefile for WRF runtime dependencies
help([[
Sets environment for WRF/WPS builds & runs (NetCDF via netcdf-links, grib2 stack).
MPI/HDF5 are expected from site modules (e.g., OpenMPI + phdf5).
]])
whatis("WRF/WPS dependency environment (NetCDF links, grib2 stack)")

-- Injected values below (templated at generation time)
LUA

  cat >> "${mod_path}" <<LUA
local prefix      = [==[${PREFIX}]==]
local netcdf      = [==[${NETCDF_LINKS}]==]
local jasperlib   = [==[${JASPERLIB}]==]
local jasperinc   = [==[${JASPERINC}]==]
local grib2_lib   = [==[${GRIB2_LIB}]==]

setenv("NETCDF", netcdf)
setenv("JASPERLIB", jasperlib)
setenv("JASPERINC", jasperinc)

prepend_path("PATH", pathJoin(netcdf, "bin"))
prepend_path("LD_LIBRARY_PATH", pathJoin(netcdf, "lib"))
prepend_path("LD_LIBRARY_PATH", grib2_lib)

-- Record discovered tool bins (from installer environment)
setenv("MPI_BIN",  [==[${MPI_BIN}]==])
setenv("HDF5_BIN", [==[${HDF5_BIN}]==])

LUA

  echo "Wrote modulefile: ${mod_path}"
  echo "To enable: module use '${ROOT_DIR}/env/modules'; module load ${MODULE_NAME}/${MODULE_VERSION}"
}

# ---------- Build sequence ----------
build_zlib
build_libpng
build_jasper
[[ "${BUILD_MPICH}" == "1" ]] && build_mpich
build_hdf5_optional   # only runs if --with-hdf5

# ---------- Link NetCDF if available ----------
detect_and_link_netcdf

# ---------- Write Lmod module ----------
write_modulefile

# ---------- Run Tests ----------
bash "${ROOT_DIR}/tests/run_env_tests.sh"

cat <<EOF

==> Complete.

Directory layout under: ${PREFIX}
  - grib2/        (zlib, libpng, jasper)
  - src/          (build sources)
  - netcdf-links/ (symlinked NetCDF C/Fortran if provided)
  $( [[ "${BUILD_MPICH}" == "1" ]] && echo "- mpich/        (MPICH built locally)" )

Next steps:
  1) Make Lmod see your modulefiles:
       module use "${ROOT_DIR}/env/modules"
  2) Load runtime stack (site modules first), then this module:
       module load gnu12/12.2.0 openmpi4/4.1.5 phdf5/1.14.0
       module load ${MODULE_NAME}/${MODULE_VERSION}
  3) Verify:
       which mpicc && which h5pcc
       echo "NETCDF=\$NETCDF" && echo "JASPERINC=\$JASPERINC"

If you didn't pass --netcdf/--netcdff, re-run with those flags or ensure netcdf modules expose nc-config/nf-config so linking can proceed.
EOF
