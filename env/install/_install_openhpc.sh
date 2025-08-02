#!/usr/bin/env bash
# _install_openhpc.sh — Minimal OpenHPC stack for WRF/WPS (install only if needed)
set -euo pipefail

# ---------- Config (EL9 x86_64 OpenHPC 3.x) ----------
OHPC_RELEASE_RPM="http://repos.openhpc.community/OpenHPC/3/EL_9/x86_64/ohpc-release-3-1.el9.x86_64.rpm"

# ---------- Helpers ----------
pkg_installed() { rpm -q "$1" >/dev/null 2>&1; }
ensure_pkg()     { pkg_installed "$1" || sudo dnf install -y "$1"; }
have_cmd()       { command -v "$1" >/dev/null 2>&1; }

source_lmod_safely() {
  # Avoid nounset issues inside vendor scripts
  set +u
  if [ -f /etc/profile.d/lmod.sh ]; then
    . /etc/profile.d/lmod.sh
  elif [ -f /usr/share/lmod/lmod/init/bash ]; then
    . /usr/share/lmod/lmod/init/bash
  fi
  set -u
}

# ---------- Base OS dependencies ----------
ensure_pkg epel-release
ensure_pkg lmod-ohpc
ensure_pkg gcc
ensure_pkg gcc-c++
ensure_pkg gcc-gfortran
ensure_pkg git-core
ensure_pkg cmake-ohpc
ensure_pkg ohpc-autotools

# ---------- SELinux (Rocky/EL) permissive if enforcing ----------
if have_cmd getenforce && [ "$(getenforce 2>/dev/null || true)" = "Enforcing" ]; then
  echo "Setting SELinux to permissive (runtime + config) ..."
  sudo setenforce 0 || true
  if [ -f /etc/selinux/config ]; then
    sudo sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
  fi
fi

# ---------- OpenHPC repo ----------
if ! pkg_installed ohpc-release; then
  sudo dnf install -y "${OHPC_RELEASE_RPM}"
  sudo dnf makecache
fi

# ---------- MPI + NetCDF/HDF5 (GNU12 + OpenMPI4) ----------
ensure_pkg gnu12-compilers-ohpc
ensure_pkg openmpi4-gnu12-ohpc
ensure_pkg netcdf-gnu12-openmpi4-ohpc
ensure_pkg netcdf-fortran-gnu12-openmpi4-ohpc
# Pulls HDF5/parallel libs commonly needed by NetCDF:
ensure_pkg ohpc-gnu12-openmpi4-io-libs
ensure_pkg ohpc-gnu12-openmpi4-parallel-libs

# ---------- (Optional) Slurm client/server — commented (not required to build WRF/WPS) ----------
# ensure_pkg ohpc-slurm-client
# ensure_pkg ohpc-slurm-server
# ensure_pkg munge

# ---------- Initialize modules and verify loads ----------
source_lmod_safely

# Try exact versions first, then fall back to any available compatible variants
module try-load gnu12/12.2.0      || module load gnu12     || true
module try-load openmpi4/4.1.5    || module load openmpi4  || true
module try-load netcdf/4.9.0      || module load netcdf    || true
module try-load netcdf-fortran/4.6.0 || module load netcdf-fortran || true

# HDF5 (parallel) may be exposed as phdf5 or hdf5 in some OHPC builds
module try-load phdf5/1.14.0 || module try-load hdf5/1.14.0 || module load hdf5 || true

echo "==> Loaded modules:"
module list || true

# ---------- Sanity checks for WRF/WPS toolchain ----------
for c in mpicc mpif90 h5pcc nc-config nf-config; do
  if ! have_cmd "$c"; then
    echo "ERROR: '$c' not found in PATH after module loads." >&2
    exit 1
  fi
done

# Confirm parallel HDF5
if h5pcc -showconfig 2>/dev/null | grep -qi 'Parallel HDF5: *yes'; then
  echo "==> Parallel HDF5: OK"
else
  echo "WARNING: HDF5 does not report Parallel=YES; check loaded modules." >&2
fi

echo "==> OpenHPC toolchain ready for WRF/WPS."
