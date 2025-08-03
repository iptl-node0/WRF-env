#!/usr/bin/env bash
# env/install/run_env_tests.sh
# Runs UCAR compiler + scripting + NetCDF(+MPI) tests.
# Fails fast and prints the exact combination that failed.
set -euo pipefail

# ---------- Locate repo root and test dirs ----------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
FC_C_DIR="${ROOT_DIR}/tests/Fortran_C_tests"
NC_MPI_DIR="${ROOT_DIR}/tests/Fortran_C_NETCDF_MPI_tests"

# ---------- Helpers ----------
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required tool: $1"; exit 1; }; }
source_lmod_safely() {
  set +u
  if [ -f /etc/profile.d/lmod.sh ]; then . /etc/profile.d/lmod.sh
  elif [ -f /usr/share/lmod/lmod/init/bash ]; then . /usr/share/lmod/lmod/init/bash
  fi
  set -u
}
run() {
  local desc="$1"; shift
  echo "==> $desc"
  if ! "$@" &> run_tests.log.tmp; then
    echo "ERROR: $desc failed."
    echo "Command: $*"
    echo "---- LOG SNIP ----"
    sed -n '1,120p' run_tests.log.tmp
    echo "------------------"
    print_diag
    exit 1
  fi
}
print_diag() {
  echo "---- ENV DIAG ----"
  echo "PATH=$PATH"
  echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-}"
  echo "NETCDF=${NETCDF:-<unset>}"
  command -v gcc   && gcc --version   | head -1
  command -v gfortran && gfortran --version | head -1
  command -v mpicc && mpicc -show 2>/dev/null | head -1 || true
  command -v mpif90 && mpif90 -show 2>/dev/null | head -1 || true
  command -v nc-config && echo "nc-libs: $(nc-config --libs 2>/dev/null)" || true
  command -v nf-config && echo "nf-libs: $(nf-config --flibs 2>/dev/null)" || true
  if [[ -f ./a.out ]]; then
    echo "NEEDED from a.out:"
    (command -v readelf >/dev/null && readelf -d ./a.out | grep NEEDED) || true
    (command -v ldd >/dev/null && ldd ./a.out) || true
  fi
  echo "------------------"
}

# define a helper near the top (after helpers)
mpirun_ok() { mpirun --oversubscribe --mca btl self,vader,tcp -np "$1" ./a.out &> run_tests.log.tmp; }


# ---------- Load modules & your env module ----------
need git; need gcc; need gfortran; need make
if ! type module >/dev/null 2>&1; then source_lmod_safely; fi
if type module >/dev/null 2>&1; then
  module try-load gnu12/12.2.0  || module load gnu12  || true
  module try-load openmpi4/4.1.5 || module load openmpi4 || true
  module try-load phdf5/1.14.0   || module try-load hdf5 || true
  echo "Loading local modules from: ${ROOT_DIR}/env/modules/WRF/lib_1.0.lua"
  module use "${ROOT_DIR}/env/modules"
  module load WRF/lib_1.0
else
  echo "ERROR: Lmod not available; cannot load toolchain/module." >&2
  exit 1
fi

# ---------- NetCDF env and lib symlink fixups ----------
: "${NETCDF:?NETCDF not set by WRF/lib_1.0}"
export PATH="${NETCDF}/bin:${PATH}"
# replace current LD_LIBRARY_PATH export with:
export LD_LIBRARY_PATH="${NETCDF}/lib:${LD_LIBRARY_PATH:-}"
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH}:${ROOT_DIR}/library/grib2/lib"

# Ensure versionless .so symlinks exist in netcdf-links/lib
#if [[ -d "${NETCDF}/lib" ]]; then
#  for base in netcdf netcdff; do
#    vers="$(ls -1 "${NETCDF}/lib/lib${base}.so."* 2>/dev/null | head -1 || true)"
#    if [[ -n "${vers}" ]]; then
#      ln -sfn "$(basename "$vers")" "${NETCDF}/lib/lib${base}.so"
#    fi
#  done
#fi

# ---------- Sanity of key tools ----------
need mpicc; need mpif90 || need mpifort
need nc-config; need nf-config
if h5pcc -showconfig 2>/dev/null | grep -qi 'Parallel HDF5: *yes'; then
  echo "==> HDF5 (parallel) : OK"
else
  echo "WARNING: HDF5 does not show Parallel=YES"
fi

# ============================================================
#           S Y S T E M   E N V I R O N M E N T   T E S T S
# ============================================================
cd "${FC_C_DIR}"
rm -f a.out *.o

run "Test #1: Fortran fixed" gfortran TEST_1_fortran_only_fixed.f
run "Run #1" ./a.out
grep -q "SUCCESS test 1 fortran only fixed format" run_tests.log.tmp || { echo "Output mismatch (Test #1)"; print_diag; exit 1; }

run "Test #2: Fortran free" gfortran TEST_2_fortran_only_free.f90
run "Run #2" ./a.out
grep -q "SUCCESS test 2 fortran only free format" run_tests.log.tmp || { echo "Output mismatch (Test #2)"; print_diag; exit 1; }

run "Test #3: C only" gcc TEST_3_c_only.c
run "Run #3" ./a.out
grep -q "SUCCESS test 3 C only" run_tests.log.tmp || { echo "Output mismatch (Test #3)"; print_diag; exit 1; }

run "Test #4: Fortran calls C (compile C)" gcc -c -m64 TEST_4_fortran+c_c.c
run "Test #4: Fortran calls C (compile F)" gfortran -c -m64 TEST_4_fortran+c_f.f90
run "Test #4: Link" gfortran -m64 TEST_4_fortran+c_f.o TEST_4_fortran+c_c.o
run "Run #4" ./a.out
grep -q "SUCCESS test 4 fortran calling c" run_tests.log.tmp || { echo "Output mismatch (Test #4)"; print_diag; exit 1; }

# scripting tests
need csh; need perl; need sh
run "Test #5: csh" ./TEST_csh.csh
grep -q "SUCCESS csh test" run_tests.log.tmp || { echo "Output mismatch (Test #5)"; print_diag; exit 1; }
run "Test #6: perl" ./TEST_perl.pl
grep -q "SUCCESS perl test" run_tests.log.tmp || { echo "Output mismatch (Test #6)"; print_diag; exit 1; }
run "Test #7: sh" ./TEST_sh.sh
grep -q "SUCCESS sh test" run_tests.log.tmp || { echo "Output mismatch (Test #7)"; print_diag; exit 1; }

# ============================================================
#         L I B R A R Y   C O M P A T I B I L I T Y   T E S T S
# ============================================================
cd "${NC_MPI_DIR}"
rm -f a.out *.o netcdf.inc

# copy required include
run "Copy netcdf.inc" bash -c 'cp "${NETCDF}/include/netcdf.inc" .'

# Test #1: Fortran + C + NetCDF
run "NetCDF #1: compile F" gfortran -c 01_fortran+c+netcdf_f.f
run "NetCDF #1: compile C" gcc     -c 01_fortran+c+netcdf_c.c
run "NetCDF #1: link" gfortran 01_fortran+c+netcdf_f.o 01_fortran+c+netcdf_c.o -L"${NETCDF}/lib" -lnetcdff -lnetcdf
run "NetCDF #1: run" ./a.out
grep -q "SUCCESS test 1 fortran + c + netcdf" run_tests.log.tmp || { echo "Output mismatch (NetCDF #1)"; print_diag; exit 1; }

# Test #2: Fortran + C + NetCDF + MPI
rm -f a.out *.o
run "NetCDF+MPI #2: compile F" mpif90 -c 02_fortran+c+netcdf+mpi_f.f
run "NetCDF+MPI #2: compile C" mpicc  -c 02_fortran+c+netcdf+mpi_c.c
run "NetCDF+MPI #2: link" mpif90 02_fortran+c+netcdf+mpi_f.o 02_fortran+c+netcdf+mpi_c.o -L"${NETCDF}/lib" -lnetcdff -lnetcdf

# Try with 2 ranks, fall back to 1 if mpirun configuration is restrictive
if mpirun_ok 2; then
  echo "==> NetCDF+MPI #2: run (2 ranks) OK"
elif mpirun_ok 1; then
  echo "==> NetCDF+MPI #2: run (1 rank) OK"
else
  echo "ERROR: NetCDF+MPI #2 run failed (np=2 and np=1)."
  echo "---- mpirun output ----"
  sed -n '1,160p' run_tests.log.tmp
  print_diag
  exit 1
fi
grep -q "SUCCESS test 2 fortran + c + netcdf + mpi" run_tests.log.tmp || { echo "Output mismatch (NetCDF+MPI #2)"; print_diag; exit 1; }

echo "==> All tests PASSED."
