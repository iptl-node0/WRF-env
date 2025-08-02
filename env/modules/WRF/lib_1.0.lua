-- Auto-generated modulefile for WRF runtime dependencies
help([[
Sets environment for WRF/WPS builds & runs (NetCDF via netcdf-links, grib2 stack).
MPI/HDF5 are expected from site modules (e.g., OpenMPI + phdf5).
]])
whatis("WRF/WPS dependency environment (NetCDF links, grib2 stack)")

-- Injected values below (templated at generation time)
local prefix      = [==[/home/s/Desktop/Software/WRF/library]==]
local netcdf      = [==[/home/s/Desktop/Software/WRF/library/netcdf-links]==]
local jasperlib   = [==[/home/s/Desktop/Software/WRF/library/grib2/lib]==]
local jasperinc   = [==[/home/s/Desktop/Software/WRF/library/grib2/include]==]
local grib2_lib   = [==[/home/s/Desktop/Software/WRF/library/grib2/lib]==]

setenv("NETCDF", netcdf)
setenv("JASPERLIB", jasperlib)
setenv("JASPERINC", jasperinc)

prepend_path("PATH", pathJoin(netcdf, "bin"))
prepend_path("LD_LIBRARY_PATH", pathJoin(netcdf, "lib"))
prepend_path("LD_LIBRARY_PATH", grib2_lib)

-- Record discovered tool bins (from installer environment)
setenv("MPI_BIN",  [==[/opt/ohpc/pub/mpi/openmpi4-gnu12/4.1.5/bin]==])
setenv("HDF5_BIN", [==[/opt/ohpc/pub/libs/gnu12/openmpi4/hdf5/1.14.0/bin]==])

