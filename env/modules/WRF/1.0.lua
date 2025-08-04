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
