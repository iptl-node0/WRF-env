# env-management-template

This package provides a starting point to standardize environment management for typical high-performance-computing software, with support for:

- Bash and other shells using dnf, yum, apt, or pacman
- Python using venv
- Built language scripts using Lmod's modules
(+r fork: includes support for R through renv and rip)

Python requires that conda not be automatically managed in the bashrc file. Make sure this is disabled (this is a typical conflict with HPC vs data analysis toolsets).
Lmod is used to allow for built scripts and dependencies (ex C, fortran, rust) to be managed per application, and is used mainly for compatibility with OpenHPC's pre-built modules. Others like IOAPI and CMAQ may be added in time.

The result is a jack-of-all-trades environment management framework which is easy to load into an existing codebase and configure for a new computer. 
This may be used for automated scripts (Agents and cron jobs), or just integrated workflows (ex. bash script sequentially calling multiple tools with complicated, multi-language, machine-specific built dependencies)

## How to Use

This repository is intended to be copied into existing bash terminal repositories to handle environment and module dependencies in a standardized way. 

.
├── copy_to_repo.sh
├── modules
│   └── lmod_test
│       └── 1.0
├── README.md
├── setup_env.sh
├── setup_system.sh
├── test_env.sh
└── tests

Current installed structure is:

/.../WRF-ohpc/env
├── config_template.txt
├── config.txt
├── install
│   └── install_sample.sh
├── modules
│   └── lmod_test
│       └── 1.0
├── README.md
├── setup_env.sh
└── setup_system.sh

1. Run bash copy_to_repo.sh ./target/repository/here

Use this to duplicate the template as part of another repository. It will create the structure shown above under the env/ folder or another folder if env/ already exists.

2. Edit config.txt with dependencies for your repository

Update the filepaths and dependency lists contained within the file to accomodate automatic setup of the local repository. This should contain all dnf or other package manager,
 pip or other python, and all openhpc or other lmod dependencies.

3. Install or Build any required compiled dependencies and settings using openHPC or locally under modules/

Prepare any one-time installation scripts required under env/install/install_(package).sh. Prepare lua lmod file 
under modules/(package)/(version).lua

This is typically done using a named subfolder under modules with other subfolders matching the version numbers or other descriptors for each built dependency. 
Note that all local modules are loaded by default - scripts inside of your repository will need to load and unload these when multiple versions are present under the env/ folder. 

(+r fork: run sudo bash setup_system.sh to install rip, ensuring support for version managed R installations by folder).

4. Run sudo bash setup_system.sh

This will install direnv, rip, add direnv and lmod hooks to bashrc, and then run any scripts in the install folder. 
It is run with sudo to interact with system folders; place any setup commands requiring sudo privileges here.

5. Run bash setup_env.sh

This will confirm the dependency list and env variables before installing each list and creating a .venv python folder and a .envrc file to automatically load and unload the 
environment when the folder is entered and exited. Most new installations will need to run 'direnv allow' afterwards to enable the package. 

6. Setup any other system dependencies or settings not covered

This may include networking steps or other connected tools, or package test scripts or cases. 
