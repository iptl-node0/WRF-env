-- -*- lua -*-
-- WRF/1.0 environment module for the WRF‑ohpc repository

whatis("Name: WRF/1.0.lua")
whatis("Version: 1.0")
whatis("Description: Weather Research and Forecasting (WRF) model; build handled by env/install/install_wrf.sh")

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
if not isloaded("netcdf")     then load("netcdf/4.9.0")     end  -- MPI‑dependent libs
if not isloaded("netcdf-fortran") then load("netcdf-fortran/4.6.0") end

-----------------------------------------------------------------------
-- Local JasPer (built by install_wrf.sh under Libraries/grib2)
-----------------------------------------------------------------------
local jasper_root = pathJoin(proj_root, "Libraries", "grib2")
setenv("JASPERINC", pathJoin(jasper_root, "include"))
setenv("JASPERLIB", pathJoin(jasper_root, "lib"))

-----------------------------------------------------------------------
-- WRF + WPS executables and core variables
-----------------------------------------------------------------------
if (mode() == "load") then
  prepend_path("PATH", pathJoin(proj_root, "WRF", "main"))
  prepend_path("PATH", pathJoin(proj_root, "WPS"))
  setenv("WRF_DIR", pathJoin(proj_root, "WRF"))
  setenv("WPS_DIR", pathJoin(proj_root, "WPS"))

  -- Gentle reminders if something is missing
  local function exists(p)
    local rc = os.execute('[ -e "'..p..'" ] > /dev/null 2>&1')
    return (type(rc) == "number" and rc == 0) or (rc == true)
  end

  local wrfexe = pathJoin(proj_root, "WRF", "main", "wrf.exe")
  local geogrid = pathJoin(proj_root, "WPS", "geogrid.exe")
  if not exists(wrfexe) or not exists(geogrid) then
    LmodMessage("[WRF] Executables not found – run env/install/install_wrf_wps.sh to build the model.")
  end
  if not exists(pathJoin(jasper_root, "lib", "libjasper.a")) then
    LmodMessage("[WRF] Local JasPer not found under "..jasper_root.." – run env/install/install_wrf.sh")
  end
end
