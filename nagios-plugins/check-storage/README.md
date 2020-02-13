## STORAGE monitoring plugin for nagios


#### What's new:

> ####  13-02-2020
######   - Reported LSI/Broadcom identification issue has been corrected

######   - Some Seagate models provide very limited S.M.A.R.T. attributes which caused the check to be skipped, this is now supported,  NOTE: Health check for such models is based on 'SMART Health Status' return value, while it's not the best way, there's nothing better available at the moment

######   - NVMe storages are now supported

######   - small fixes

#
##### What it does:

###### This plugin will monitor health & missing components of:

###### -  Hardware RAID (supported RAID controllers: LSI, 3ware, Areca, Adaptec):

###### -  Controller itself, virtual drives, drive enclosures, physical drives in the RAID setup via smart realloc value

###### -  Software RAID via mdadm tool (arrays and drives)

###### -  ZFS pools

###### -  It will also monitor all the drives (via smartctl) detected in non-RAID / non-ZFS (or mixed) enviroments.


##### What's required:

###### For Areca - CLI version <= 1.14.2 is required

###### For Adaptec - pcre2grep tool (pcre.org) is required for SMART regexp

###### For Adaptec - compat-libstdc++ package is required, CLI is dynamically linked

###### proper RAID utilities to query the RAID controller (can be found in hwraid_utils, executables needs to be placed in /opt dir on monitored server)

#### example output:


Sofware RAID only (drive /dev/sdb in array md0 reports 716 realloc sectors):

[root@strdev3 ~]# ./check-storage.sh

`[STORAGE][SWR]::Array:md2:Health: OK (state/failed_dev/removed_dev: clean/0/0):Array:md1:Health: OK (state/failed_dev/removed_dev: clean/0/0):Array:md0:Health: OK (state/failed_dev/removed_dev: clean/0/0):[STORAGE]drv:/dev/sda:Health: OK (realloc: 0):drv:/dev/sdb:Health: CRITICAL (realloc: 716):drv:/dev/sdc:Health: OK (realloc: 1):drv:/dev/sdd:Health: OK (realloc: 0):`

-

Sofware RAID only (array md127 reports 4 removed drives):

[root@strdev5 ~]# ./check-storage.sh

`[STORAGE][SWR]::Array:md127:Health: CRITICAL (state/failed_dev/removed_dev: active/0/4):[STORAGE]drv:/dev/sda:Health: OK (realloc: 0):drv:/dev/sdb:Health: OK (realloc: 0):`

-

Hardware RAID (drive p0 reports ECC-ERROR):

[root@strdev2 ~]# ./check-storage.sh

`[STORAGE][3Ware]::CTL: c0: Health: OK (NotOpt:0)::Unit: u0: Health: OK (Status: VERIFYING, type/size: RAID-10/1862.62GB)::Drive: p0: Health: CRITICAL (Status/ReallocSect: ECC-ERROR/0, VPort/Size/Type: p0/931.51GBGB/SATA)::Drive: p1: Health: OK (Status/ReallocSect: OK/0, VPort/Size/Type: p1/931.51GBGB/SATA)::Drive: p2: Health: OK (Status/ReallocSect: OK/0, VPort/Size/Type: p2/931.51GBGB/SATA)::Drive: p3: Health: OK (Status/ReallocSect: OK/0, VPort/Size/Type: p3/931.51GBGB/SATA)::[STORAGE]drv:0:Health: OK (realloc: 0):drv:1:Health: OK (realloc: 0):drv:2:Health: OK (realloc: 0):drv:3:Health: OK (realloc: 0):`

-

Checks on unsupported RAID controller will be limited to drives & software arrays if present:

[root@strdev1 ~]# ./check-storage.sh

`[HWR]:Found unsupported RAID card :: [STORAGE][SWR]::Array:md124:Health: OK (state/failed_dev/removed_dev: active/0/0):Array:md125:Health: CRITICAL (state/failed_dev/removed_dev: active/0/1):Array:md126:Health: CRITICAL (state/failed_dev/removed_dev: clean/0/1):Array:md127:Health: CRITICAL (state/failed_dev/removed_dev: clean/0/1):[STORAGE]drv:/dev/sdb:Health: OK (realloc: 0):drv:/dev/sdc:Health: OK (realloc: 0):drv:/dev/sdd:Health: OK (realloc: 0):drv:/dev/sde:Health: OK (realloc: 0):drv:/dev/sdf:Health: OK (realloc: 0):drv:/dev/sdg:Health: OK (realloc: 0):drv:/dev/sdh:Health: OK (realloc: 0):drv:/dev/sdi:Health: OK (realloc: 0):drv:/dev/sdj:Health: OK (realloc: 0):drv:/dev/sdk:Health: OK (realloc: 0):drv:/dev/sdl:Health: OK (realloc: 6):drv:/dev/sdm:Health: OK (realloc: 6):drv:/dev/sdn:Health: OK (realloc: 16):drv:/dev/sdo:Health: OK (realloc: 0):drv:/dev/sdp:Health: OK (realloc: 0):`

-

Checks on ZFS pool:

[root@strdev4 ~]# ./check-storage.sh

`[ZFS]::Health: CRITICAL (name/size/health: pool1/2.72T/DEGRADED):[STORAGE]drv:/dev/sda:Health: OK (realloc: S_NOATTR):drv:/dev/sdb:Health: OK (realloc: 0):drv:/dev/sdc:Health: OK (realloc: 0):drv:/dev/sdd:Health: OK (realloc: S_NOATTR):drv:/dev/sde:Health: OK (realloc: 0):drv:/dev/sdf:Health: OK (realloc: 0):drv:/dev/sdg:Health: OK (realloc: 0):`
