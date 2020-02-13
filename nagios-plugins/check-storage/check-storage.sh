#!/bin/bash
#
# Nagios plugin for Software/Hardware RAID and non-RAID storages; asmo@conseev
#
# Supported RAID controllers: LSI, 3ware, Areca, Adaptec
# notes:
#	- For Areca - CLI version <= 1.14.2 is required
#	- For Adaptec - pcre2grep tool (pcre.org) is required for SMART regexp
#	- For Adaptec - compat-libstdc++ package is required, CLI is dynamically linked
#
# usage: ./check-storage
#	 ./check-storage show_error_counters    # display counters of critical events
#
# v0.4(4) - 22-01-2020
#
###

STATE_OK=0
STATE_CRITICAL=2


# Detect all controllers and check each controller's health, all VDs per controller
# and all physical drives behind controller

# LSI RAID Controllers
function lsi_hw_raid_check() {
	is_critical=0

	# storcli absolute path
	# use the old version if installed
	if [[ -x /opt/storcli-1.15 ]]; then
		# 1.15 works with 2.6.18 kernel (so I don't have to mess with MegaCLI, uff.)
		r_cli=/opt/storcli-1.15
	  else
		r_cli=/opt/storcli64
	fi
	if [[ ! -x ${r_cli} ]]; then echo "${r_cli} not found, exiting" ; exit 2 ; fi

	# use SHM in case the OS became RO, capture $r_cli for MegaCLI if needed
	${r_cli} show >/dev/shm/.hwr_ctl.tmp; cli_ret=$?

	# amount of RAID controllers
	ctl_ids=$(cat /dev/shm/.hwr_ctl.tmp|awk '/^-------+$/ && a++ {next}; a == 2')

	echo -n "[STORAGE][LSI]::"
	# Check every available controller
	while read -r current_ctl; do

		current_ctl_id=$(echo ${current_ctl}|awk '{print $1}')
		echo -n "CTL: ${current_ctl_id}: "

		# Check and report health (Hlth) of current controller
		# anything else than 'Opt' state is considered critical
		current_ctl_hlth=$(echo ${current_ctl}|grep -oE '[^ ]+$')

		if [[ "${current_ctl_hlth}" = "Opt" ]] || [[ "${current_ctl_hlth}" = "NdAtn" ]]; then
			echo -n "Health: OK (${current_ctl_hlth});;"
		  else
			echo -n "Health: CRITICAL (${current_ctl_hlth});;"
			let is_critical+=1
		fi


		# Check VDs health
		# anything else than 'Optl' state is considered critical
		${r_cli} /c${current_ctl_id}/vall show|awk '/^-------+$/ && a++ {next}; a == 2' >/dev/shm/.vd_list.tmp
		vd_ids=$(cat /dev/shm/.vd_list.tmp)

		# check whether VDs are configured
		vd_present=$(cat /dev/shm/.vd_list.tmp|wc -l)
		if [[ ${vd_present} -gt 0 ]]; then
			while read -r current_vd; do

				# get VD details
				vd_type=$(echo ${current_vd}|awk '{print $2}')  ; vd_size=$(echo ${current_vd}|awk '{print $9,$10}')
				vd_state=$(echo ${current_vd}|awk '{print $3}') ; vd_dg_vd=$(echo ${current_vd}|awk '{print $1}')

				echo -n "VD: ${vd_dg_vd}: "

				if [[ "${vd_state}" = "Optl" ]]; then
					echo -n "Health: OK (DG/VD: ${vd_dg_vd}, type/size/state: ${vd_type}/${vd_size}/${vd_state});;"
				  else
					echo -n "Health: CRITICAL (DG/VD: ${vd_dg_vd}, type/size/state: ${vd_type}/${vd_size}/${vd_state});;"
					let is_critical+=1
				fi
			done <<< "${vd_ids}"
		fi

		# check for drives with and without enclosures
		enc_drives=$(${r_cli} /c${current_ctl_id}/eALL/sALL show|grep "^Description"|awk -F"= " '{print $NF}')
		non_enc_drives=$(${r_cli} /c${current_ctl_id}/sALL show|grep "^Description"|awk -F"= " '{print $NF}')

		# Check all drives health (Media/BBM counters) in current controller ($current_ctl_id)
		# values higher than 0 are considered critical
		function lsi_hw_raid_check_drives() {
			while read -r current_drive && [[ ! -z ${current_drive} ]]; do

				err_media=$(${r_cli} ${current_drive} show all|grep "Media Error Count"|grep -oE '[^ ]+$')
		#		err_other=$(${r_cli} ${current_drive} show all|grep "Other Error Count"|grep -oE '[^ ]+$')
				err_bbm=$(${r_cli} ${current_drive} show all|grep "BBM Error Count"|grep -oE '[^ ]+$')

				if [[ -z ${err_bbm} ]]; then err_bbm=NA; fi

				if [[ ! ${err_media} -gt ${max_media_err_cnt} ]] && [[ ${err_bbm}  -eq 0 ]]; then
					echo -n "drv: ${current_drive} - OK (ERR count(Media/BBM): ${err_media}/${err_bbm});"
				  else
					echo -n "drv: ${current_drive} - CRITICAL (ERR count(Media/BBM): ${err_media}/${err_bbm});"
					let is_critical+=1
				fi
			done <<< "${drive_ids}"
		}

		# Get all drive IDs for further health check
		if [[ "${enc_drives}" != "No drive found!" ]]; then
			drive_ids=$(${r_cli} /c${current_ctl_id}/eALL/sALL show all|grep "^Drive .* State :$"|awk '{print $2}')
			lsi_hw_raid_check_drives
		fi
		if [[ "${non_enc_drives}" != "No drive found!" ]]; then
			drive_ids=$(${r_cli} /c${current_ctl_id}/sALL show all|grep "^Drive .* State :$"|awk '{print $2}')
			lsi_hw_raid_check_drives
		fi


	done <<< "${ctl_ids}"
	rm -f /dev/shm/.hwr_ctl.tmp /dev/shm/.vd_list.tmp
}

# Areca RAID Controllers
# note: this function will NOT work with latest 'areca-cli', v1.14.2 is required
function areca_hw_raid_check() {
	is_critical=0

	# Areca cli absolute path
	r_cli=/opt/areca_cli
	if [[ ! -x ${r_cli} ]]; then echo "${r_cli} not found, exiting" ; exit 2 ; fi

	# amount of RAID controllers
	ctl_ids=$(${r_cli} hw info|grep "^\[Enclosure#"|awk '{print $1}'|cut -d'#' -f2)

	echo -n "[STORAGE][Areca]::"
	# Check every available controller
	while read -r current_ctl; do

		current_ctl_id=${current_ctl}
		echo -n "CTL: ${current_ctl_id}: "

		# Areca directory for cli config
		r_cli_cfg_path=$(dirname ${r_cli})

		# Areca controller is protected by default password so it needs to be set
		# per controller otherwise some checks will be denied
		${r_cli} 1>/dev/null 2>/dev/null set curctrl=${current_ctl_id} password=0000

		# Checking controller status via return value
		current_ctl_hlth=$(${r_cli} 1>/dev/null 2>/dev/null hw info;echo $?)

		if [[ ${current_ctl_hlth} -eq 0 ]]; then
			echo -n "Health: OK (${current_ctl_hlth});;"
		  else
			echo -n "Health: CRITICAL (${current_ctl_hlth});;"
			let is_critical+=1
		fi


		## Check RAID set(s) health via RAID set functions (rsf)
		${r_cli} rsf info|awk '/^=======+$+/ && a++ {next}; a == 1;'|grep "===" -v >/dev/shm/.rsf_list.tmp
		rsf_ids=$(cat /dev/shm/.rsf_list.tmp)

		while read -r current_rs; do

			# get RS details
			rsf_name=$(echo ${current_rs}|awk '{print $2}') ; rsf_disks_num=$(echo ${current_rs}|awk '{print $3}')
			rsf_size=$(echo ${current_rs}|awk '{print $4}') ; rsf_state=$(echo ${current_rs}|awk '{print $7}')

			echo -n "RS: ${rsf_name}: "

			if [[ "${rsf_state}" = "Normal" ]]; then
				echo -n "Health: OK (State: ${rsf_state}, size/disks: ${rsf_size}/${rsf_disks_num});;"
			  else
				echo -n "Health: CRITICAL (State: ${rsf_state}, size/disks: ${rsf_size}/${rsf_disks_num});;"
				let is_critical+=1
			fi

		done <<< "${rsf_ids}"

		## Check RAID Volume set(s) health via RAID volume functions (vsf)
		${r_cli} vsf info|awk '/^=======+$+/ && a++ {next}; a == 1;'|grep "===" -v >/dev/shm/.vsf_list.tmp
		vsf_ids=$(cat /dev/shm/.vsf_list.tmp)

		while read -r current_vs; do

			current_vd_id=$(echo ${current_vs}|awk '{print $1}')

			${r_cli} vsf info vol=${current_vd_id} | \
				awk '/^=======+$+/ && a++ {next}; a == 1;'|grep "===" -v >/dev/shm/.curr_vd_hlth.tmp

			# get VS details
			vsf_name=$(grep "^Volume Set Name" /dev/shm/.curr_vd_hlth.tmp|awk -F": " '{print $2}'|sed 's/ //g')
			vsf_level=$(grep "^Raid Level" /dev/shm/.curr_vd_hlth.tmp|awk -F": " '{print $2}')
			vsf_size=$(grep "^Volume Capacity" /dev/shm/.curr_vd_hlth.tmp|awk -F": " '{print $2}')
			vsf_state=$(grep "^Volume State" /dev/shm/.curr_vd_hlth.tmp|awk -F": " '{print $2}')

			echo -n "VS: ${vsf_name}: "

			if [[ "${vsf_state}" = "Normal" ]]; then
				echo -n "Health: OK (State: ${vsf_state}, level/size ${vsf_level}/${vsf_size});;"
			  else
				echo -n "Health: CRITICAL (State: ${vsf_state}, level/size ${vsf_level}/${vsf_size});;"
				let is_critical+=1
			fi

		done <<< "${vsf_ids}"

		# Get all drive IDs for further health check
		${r_cli} disk info|awk '/^=======+$+/ && a++ {next}; a == 1;'|grep -E '(===| N.A.)' -v >/dev/shm/.disk_list.tmp
		disk_ids=$(cat /dev/shm/.disk_list.tmp)

		while read -r current_disk; do

			current_disk_id=$(echo ${current_disk}|awk '{print $1}')

			${r_cli} disk info drv=${current_disk_id} | \
				awk '/^=======+$+/ && a++ {next}; a == 1;'|grep "===" -v >/dev/shm/.curr_disk_hlth.tmp

			# Get current drive details
			cur_drive_loc=$(grep "^Device Location" /dev/shm/.curr_disk_hlth.tmp|awk -F": " '{print $2}')
			cur_drive_media=$(grep "^Media Error Count" /dev/shm/.curr_disk_hlth.tmp|awk -F": " '{print $2}')
			cur_drive_state=$(grep "^Device State" /dev/shm/.curr_disk_hlth.tmp|awk -F": " '{print $2}')

			if [[ ! ${cur_drive_media} -gt ${max_media_err_cnt} ]] && [[ "${cur_drive_state}" = "NORMAL" ]]; then
				echo -n "drv: ${cur_drive_loc} - OK (ERR count/State: ${cur_drive_media}/${cur_drive_state});"
			  else
				echo -n "drv: ${cur_drive_loc} - CRITICAL (ERR count/State: ${cur_drive_media}/${cur_drive_state});"
				let is_critical+=1
			fi

		done <<< "${disk_ids}"

	done <<< "${ctl_ids}"
	rm -f /dev/shm/.rsf_list.tmp /dev/shm/.vsf_list.tmp /dev/shm/.curr_vd_hlth.tmp /dev/shm/.disk_list.tmp /dev/shm/.curr_disk_hlth.tmp
}

# 3Ware RAID Controllers
function 3ware_hw_raid_check() {
	is_critical=0

	# 3Ware cli absolute path
	r_cli=/opt/tw_cli.x86_64
	if [[ ! -x ${r_cli} ]]; then echo "${r_cli} not found, exiting" ; exit 2 ; fi

	# amount of RAID controllers
	ctl_ids=$(${r_cli} show|awk '/^----+$+/ && a++ {next}; a == 1'|grep "^----" -v|sed '/^$/d')

	echo -n "[STORAGE][3Ware]::"
	# check every available controller
	while read -r current_ctl; do

		current_ctl_id=$(echo ${current_ctl}|awk '{print $1}')
		echo -n "CTL: ${current_ctl_id}: "

		# CTL status is critical if NotOpt > 1
		current_ctl_hlth=$(echo ${current_ctl}|awk '{print $6}')

		if [[ "${current_ctl_hlth}" -eq 0 ]]; then
			echo -n "Health: OK (NotOpt:${current_ctl_hlth});;"
		  else
			echo -n "Health: CRITICAL (NotOpt:${current_ctl_hlth});;"
			let is_critical+=1
		fi

		# check unit status, critical if not 'OK', pos 3
		${r_cli} /${current_ctl_id} show unitstatus|awk '/^----+$+/ && a++ {next}; a == 1'|grep "^----" -v|sed '/^$/d' >/dev/shm/.3w_unit_list.tmp
		unit_list=$(cat /dev/shm/.3w_unit_list.tmp)

		while read -r current_unit; do

			# get unit details
			unit_name=$(echo ${current_unit}|awk '{print $1}') ; unit_type=$(echo ${current_unit}|awk '{print $2}')
			unit_size=$(echo ${current_unit}|awk '{print $7}') ; unit_state=$(echo ${current_unit}|awk '{print $3}')

			echo -n "Unit: ${unit_name}: "

			if [[ "${unit_state}" = "OK" ]] || [[ "${unit_state}" = "VERIFYING" ]]; then
				echo -n "Health: OK (Status: ${unit_state}, type/size: ${unit_type}/${unit_size}GB);;"
			  else
				echo -n "Health: CRITICAL (Status: ${unit_state}, type/size: ${unit_type}/${unit_size}GB);;"
				let is_critical+=1
			fi

		done <<< "${unit_list}"

		# check all drives status, critical if not 'OK', pos 2
		${r_cli} /${current_ctl_id} show drivestatus|grep NOT-PRESENT -v|awk '/^----+$+/ && a++ {next}; a == 1'|grep "^----" -v | \
			sed '/^$/d'|sed 's/ GB /GB /g' >/dev/shm/.3w_drive_list.tmp
		drive_list=$(cat /dev/shm/.3w_drive_list.tmp)

		while read -r current_drive; do

			# get drive details, check status & reallocated sectors, critical if non 'OK' or realloc counter > 0
			drive_vport=$(echo ${current_drive}|awk '{print $1}') ; drive_type=$(echo ${current_drive}|awk '{print $5}')
			drive_size=$(echo ${current_drive}|awk '{print $4}') ; drive_state=$(echo ${current_drive}|awk '{print $2}')
			rasect_cnt=$(${r_cli} /${current_ctl_id}/${drive_vport} show rasect|grep =|awk '{print $NF}')

			echo -n "Drive: ${drive_vport}: "

			if [[ "${drive_state}" = "OK" ]] || [[ "${drive_state}" = "VERIFYING" ]] && [[ ! ${rasect_cnt} -gt ${max_realloc_cnt} ]]; then
				echo -n "Health: OK (Status/ReallocSect: ${drive_state}/${rasect_cnt}, VPort/Size/Type: ${drive_vport}/${drive_size}GB/${drive_type});;"
			  else
				echo -n "Health: CRITICAL (Status/ReallocSect: ${drive_state}/${rasect_cnt}, VPort/Size/Type: ${drive_vport}/${drive_size}GB/${drive_type});;"
				let is_critical+=1
			fi

		done <<< "${drive_list}"


	done <<< "${ctl_ids}"
	rm -f /dev/shm/.3w_unit_list.tmp
	# /dev/shm/.3w_drive_list.tmp

}

# Adaptec RAID Controllers
# note: arcconf is dynamically linked and require libstdc++.so.5 which can be installed
# via 'yum install compat-libstdc++-33-3.2.3-72.el7.x86_64', seems it's basent by default
function adaptec_hw_raid_check() {
	is_critical=0

	# arcconf absolute path
	r_cli=/opt/arcconf-7.31.x64
	if [[ ! -x ${r_cli} ]]; then echo "${r_cli} not found, exiting" ; exit 2 ; fi

	# need to scan for controller IDs manually as there's no LIST command in arcconf 7.31 (or im blind)
	for i in 0 1 2 3 4 5 6 7 8 9 10; do
		is_ctl=$(${r_cli} 1>/dev/null 2>/dev/null getstatus $i;echo $?)
		if [[ ${is_ctl} -eq 0 ]]; then
			ctl_ids+=("${i}")
		fi
	done

	echo -n "[STORAGE][Adaptec]::"
	# check every available controller
	for current_ctl in $(echo ${ctl_ids[@]}); do

		# CTL status is critical if other than 'Optimal'
		current_ctl_hlth=$(${r_cli} getconfig ${current_ctl} ad|grep "Controller Status"|awk '{print $4}')

		if [[ "${current_ctl_hlth}" = "Optimal" ]]; then
			echo -n "Health: OK (${current_ctl_hlth});;"
		  else
			echo -n "Health: CRITICAL (${current_ctl_hlth});;"
			let is_critical+=1
		fi

		# check health of logical devices (LD)
		for current_vol in $(${r_cli} getconfig ${current_ctl} ld|grep "^Logical device number"|awk '{print $NF}'); do

			# get LD details
			${r_cli} getconfig ${current_ctl} ld ${current_vol} >/dev/shm/.adp_ldvol.tmp

			ld_level=$(grep "RAID level" /dev/shm/.adp_ldvol.tmp|awk '{print $NF}')
			ld_size=$(grep "Size" /dev/shm/.adp_ldvol.tmp|awk '{print $3$4}')
			ld_state=$(grep "Status of logical device" /dev/shm/.adp_ldvol.tmp|awk '{print $NF}')

			echo -n "LD: ${current_vol}: "

			if [[ "${ld_state}" = "Optimal" ]]; then
				echo -n "Health: OK (${ld_state}, level/size: ${ld_level}/${ld_size});;"

			  else
				echo -n "Health: CRITICAL (${ld_state}, level/size: ${ld_level}/${ld_size});;"
				let is_critical+=1
			fi

			# check LD segments state
			ld_segments=$(grep "Segment" /dev/shm/.adp_ldvol.tmp|awk '{print $2,$4,$5}')

			while read -r current_ld_segment; do

				seg_id=$(echo ${current_ld_segment}|awk '{print $1}') ; seg_state=$(echo ${current_ld_segment}|awk '{print $2}')
				seg_path=$(echo ${current_ld_segment}|awk '{print $3}')

				if [[ -z "${seg_path}" ]]; then seg_path=NA; fi

				if [[ "${seg_state}" = "Present" ]]; then
					echo -n "Segment ${current_ld_segment}: OK (${seg_state}, path: ${seg_path})"
				  else
					echo -n "Segment ${current_ld_segment}: CRITICAL (${seg_state}, path: ${seg_path})"
					let is_critical+=1
				fi

			done <<< "${ld_segments}"

		done

		# Adaptec, as absolutely worst RAID CLI on earth is forcing its users to parse that ugly SMART dump.
		# selected raw SMART values to check:
		# 0x05 - Reallocated Sectors Count
		# 0x0A - Spin Retry Count
		# 0xC5 - Current Pending Sector Count
		# 0xC6 - (Offline) Uncorrectable Sector Count[

		# get SMART dump and wipe trailing spaces for further parsing
		${r_cli} getsmartstats ${current_ctl} tabular |awk '{$1=$1;print}' >/dev/shm/.adp_rawsmart.tmp

		# get drive ID and selected raw values
		# format: 'ID attribute1,value attribute2,value attribute3,value attribute4,value'
		echo $(${bin_p2g} -M --om-separator=, -o3 -o4 -o6 \
			"(PhysicalDriveSmartStats)(\n.*\n.*.)(.. [0-9]*$)|(0x05|0x0A|0xC5|0xC6)(\n.*\n.*\n\s*rawValue.*. )([0-9]*$)" \
			/dev/shm/.adp_rawsmart.tmp) | sed 's/ .. /\n/g'|sed 's/^.. //g' >/dev/shm/.adp_sel_raw.tmp

		drive_list=$(cat /dev/shm/.adp_sel_raw.tmp)
		while read -r current_drive; do

			# get raw values per drive
			drive_id=$(echo ${current_drive}|awk '{print $1}')
			x05=$(echo ${current_drive}|awk '{print $2}'|cut -d',' -f2) ; x0a=$(echo ${current_drive}|awk '{print $3}'|cut -d',' -f2)
			xc5=$(echo ${current_drive}|awk '{print $4}'|cut -d',' -f2) ; xc6=$(echo ${current_drive}|awk '{print $5}'|cut -d',' -f2)

			echo -n "Drive: ${drive_id}:"
			if [[ ! ${x05} -gt ${max_realloc_cnt} ]] && [[ ${x0a} -eq 0 ]]; then
				if [[ ${xc5} -eq 0 ]] && [[ ${xc6} -eq 0 ]]; then
					echo -n "Health: OK (0x05/0x0A/0xC5/0xC6: ${x05}/${x0a}/${xc5}/${xc6});"
				  else
					echo -n "Health: CRITICAL (0x05/0x0A/0xC5/0xC6: ${x05}/${x0a}/${xc5}/${xc6});"
					let is_critical+=1
				fi
			  else
				echo -n "Health: CRITICAL (0x05/0x0A/0xC5/0xC6: ${x05}/${x0a}/${xc5}/${xc6});"
				let is_critical+=1
			fi

		done <<< "${drive_list}"

	done
	rm -f /dev/shm/.adp_ldvol.tmp /dev/shm/.adp_rawsmart.tmp /dev/shm/.adp_sel_raw.tmp
}

# Software RAID checks
# Checks include data from 'mdadm -D' per array and following SMART values per drive:
#   0x05 - Reallocated Sectors Count
function software_raid_check() {
	is_critical=0

	r_cli=${bin_mdadm}
	if [[ ! -x ${r_cli} ]]; then echo "${r_cli} not found, exiting" ; exit 2 ; fi

	# get all arrays names
	sw_arrays=$(grep -o "^md[_,a-z,0-9]*" /proc/mdstat)


	echo -n "[STORAGE][SWR]::"
	while read -r current_array; do

		${r_cli} -D /dev/${current_array} >/dev/shm/.sw_carray.tmp
		echo -n "Array:${current_array}:"

		# get array details
		ar_state=$(grep -oP "(?<=State : )[a-zA-Z]*" /dev/shm/.sw_carray.tmp)
		ar_active_dev=$(grep "Active Devices :" /dev/shm/.sw_carray.tmp|awk '{print $NF}')
		ar_failed_dev=$(grep "Failed Devices :" /dev/shm/.sw_carray.tmp|awk '{print $NF}')
		ar_level=$(grep "Raid Level :" /dev/shm/.sw_carray.tmp|awk '{print $NF}')
		ar_removed=$(grep "removed" /dev/shm/.sw_carray.tmp|awk '{print $NF}'|wc -l)

		if [[ "${ar_state}" = "active" ]] || [[ "${ar_state}" = "clean" ]] || [[ "${ar_state}" = "inactive" ]] || [[ "${ar_level}" = "container" ]] && [[ ${ar_removed} -eq 0 ]] && [[ ${ar_failed_dev} -eq 0 ]]; then
			if [[ ${ar_level} = "container" ]]; then
				ar_state=container ; ar_failed_dev=NA
			fi
			echo -n "Health: OK (state/failed_dev/removed_dev: ${ar_state}/${ar_failed_dev}/${ar_removed});"
		  else
			echo -n "Health: CRITICAL (state/failed_dev/removed_dev: ${ar_state}/${ar_failed_dev}/${ar_removed});"
			let is_critical+=1
		fi

	done <<< "${sw_arrays}"
}

function check_zfs_pools() {
	if [[ -x ${bin_zpool} ]]; then

		zfs_pools=$(${bin_zpool} list -H -o name,size,health)
		if [[ ! -z ${zfs_pools} ]]; then
			echo -n "[ZFS]::"

			while read -r current_pool; do

				# get pool details
				pool_name=$(echo ${current_pool}|awk '{print $1}') ; pool_size=$(echo ${current_pool}|awk '{print $2}')
				pool_health=$(echo ${current_pool}|awk '{print $3}')

				if [[ "${pool_health}" = "ONLINE" ]]; then
					echo -n "Health: OK (name/size/health: ${pool_name}/${pool_size}/${pool_health});"
				  else
					echo -n "Health: CRITICAL (name/size/health: ${pool_name}/${pool_size}/${pool_health});"
					let is_critical+=1
				fi

			done <<< "${zfs_pools}"

		  else
			true
		fi
	  else
		true
	fi
}

function check_nvme() {

	echo -n "[NVME]::"
	# exclude fd, sr and ram devices to avoid timeout waits
	nvme_devices=$(${bin_lsblk} -e 1,2,11 -nd --output NAME|grep ^nvme|sort -n)

	while read -r current_nvme; do

		${bin_nvme} smart-log /dev/${current_nvme} >/dev/shm/.nvme_cdrv

		# https://nvmexpress.org/wp-content/uploads/NVM-Express-1_4-2019.06.10-Ratified.pdf 5.14.1.2
		# cw - Critical Warning (>1)
		# pu - Percentage USed (>95)
		# me - Media Errors (>49)
		s_cw=$(grep "^critical_warning\s" /dev/shm/.nvme_cdrv|awk '{print $NF}')
		s_pu=$(grep "^percentage_used\s" /dev/shm/.nvme_cdrv|awk '{print $NF}'|cut -d'%' -f1)
		s_me=$(grep "^media_errors\s" /dev/shm/.nvme_cdrv|awk '{print $NF}')

		echo -n "drv:/dev/${current_nvme}:"

		if [[ ${s_cw} -lt 2 ]] && [[ ${s_pu} -lt 95 ]] && [[ ${s_me} -lt 50 ]]; then
			echo -n "Health OK (cw/pu/me: ${s_cw}/${s_pu}/${s_me});"
		  else
			echo -n "Health: CRITICAL ((cw/pu/me: ${s_cw}/${s_pu}/${s_me});"
			let is_critical+=1
		fi

	done <<< "${nvme_devices}"
}

function check_drives() {
	# smartctl shipped with CentOS 5.7 (ie vpsnode1) doesn't have --scan option
	valid_sctl=$(${bin_smartctl} -h|grep scan$)
	if [[ -z ${valid_sctl} ]]; then
		echo -n "* * * drive checks skipped, no --scan support in smartctl, please update smartmontools * * *"
		let is_critical+=1
		nagios_states
	fi

	# default IDs
	${bin_smartctl} --scan|awk '{print $1}' >/dev/shm/.sw_drv_list.tmp
	drive_ids=$(cat /dev/shm/.sw_drv_list.tmp)

	if [[ "${sctl}" = "lsi" ]]; then
		${bin_smartctl} --scan >/dev/shm/.smart_lsi.tmp
		is_megaraid=$(grep -ql "/dev/bus" /dev/shm/.smart_lsi.tmp;echo $?)
	fi

	# 3ware require '-d 3ware,N' for smartctl
	if [[ "${sctl}" = "3ware" ]]; then
		drive_ids=$(cat /dev/shm/.3w_drive_list.tmp|awk '{print $1}'|sed 's/^p//g')
	fi

	# LSI require '-d megaraid,N for smartctl on some hosts
	if [[ ${sctl} = "lsi" ]]; then
		if [[ ${is_megaraid} -eq 0 ]]; then
			drive_ids=$(grep "/dev/bus" /dev/shm/.smart_lsi.tmp|awk -F" #" '{print $1}')
		  else
                        drive_ids=$(cat /dev/shm/.smart_lsi.tmp|awk '{print $1}')
		fi
	fi

	# check SMART 0x05 value
	function check_sattr() {
		if [[ -z ${err_realloc} ]]; then
		
			# query the device just once
			${bin_smartctl} ${1} >/dev/shm/.drv_vendor
			s_vendor=$(grep -P "^Vendor:\s" /dev/shm/.drv_vendor|awk '{print $NF}')

			if [[ ! ${s_vendor} = "SEAGATE" ]]; then
				s_vendor=$(grep -P "^Device Model:" /dev/shm/.drv_vendor|awk '{print $3}')
			fi
			
			# identify Seagate
			if [[ ${s_vendor} = "SEAGATE" ]]; then

				# notify about alternative verification if it's other than Realloc counter test
				verification_type=SGT

				# switch SMART query to Health
				new_query=$(echo ${1}|sed 's/-i/-H/g')

				# get Seagate health status via 'SMART Health Status' since it lacks the usual values
				sgt_health=$(${bin_smartctl} ${new_query}|grep "Health Status: "|awk -F": " '{print $NF}')

				err_realloc="SEAGATE:${sgt_health}"
				return 0
			fi

			# identify PNY
			if [[ ${s_vendor} = "PNY" ]]; then
			
				verification_type=PNY

				# switch SMART query to ALL
				new_query=$(echo ${1}|sed 's/-i/-a/g')

				# get PNY health status via SMART 231 attribute, the 'common' name for 231 is incorrect
				# (https://www.smartmontools.org/ticket/1281) but the attribute itself is returning correct Life Left
				# value, all PNY devices will be checked that way but the bug was found on PNY C900 model

				pny_health=$(${bin_smartctl} ${new_query}|grep -P "^231\s"|awk '{print $NF}')

				# Life Left, %
				err_realloc="${pny_health}"
				return 0
			fi

		 err_realloc="S_NOATTR"; fi
	}

	# smart 0x05 value is named differently depending on the drive model, define the names here to avoid
	# long grep lines within 'current_drive'
	s5_1=Reallocated_Sector_Ct
	s5_2=Retired_Block_Count
	# SSD
	s5_3=Reallocate_NAND_Blk_Cnt

	echo -n "[STORAGE]"
	while read -r current_drive; do

		if [[ ${sctl} = "3ware" ]]; then
			# check whether SMART is enabled
			${bin_smartctl} -d 3ware,${current_drive} -a /dev/tw?0 >/dev/shm/.sw_smctl_dump.tmp
			is_smart=$(grep "SMART support is:\s*Disabled$" /dev/shm/.sw_smctl_dump.tmp|awk '{print $NF}')

			if [[ -z "${is_smart}" ]]; then
				err_realloc=$(${bin_smartctl} -d 3ware,${current_drive} -a /dev/tw?0|egrep "(${s5_1}|${s5_2}|${s5_3})"|awk '{print $NF}')
				check_sattr "-d 3ware,${current_drive} -i /dev/tw?0"
			  else
				err_realloc="SMART_disabled"
			fi

		  elif [[ ${sctl} = "lsi" ]]; then
			# check whether SMART is enabled
			${bin_smartctl} -a ${current_drive} >/dev/shm/.sw_smctl_dump.tmp
			is_smart=$(grep "SMART support is:\s*Disabled$" /dev/shm/.sw_smctl_dump.tmp|awk '{print $NF}')

			if [[ -z "${is_smart}" ]]; then
				err_realloc=$(${bin_smartctl} -a ${current_drive} |egrep "(${s5_1}|${s5_2}|${s5_3})"|awk '{print $NF}')
				check_sattr "-i ${current_drive}"
			  else
				err_realloc="SMART_disabled"
			fi

		  else

			# check whether SMART is enabled
			${bin_smartctl} -a ${current_drive} >/dev/shm/.sw_smctl_dump.tmp
			is_smart=$(grep "SMART support is:\s*Disabled$" /dev/shm/.sw_smctl_dump.tmp|awk '{print $NF}')

			if [[ -z "${is_smart}" ]]; then

				if [[ ${sctl} = "Areca" ]]; then
					err_realloc=$(echo $(smartctl -a ${current_drive} |egrep '(^read:|^write:)'|awk '{print $NF}')|sed 's/ /+/g'|bc)
				  else
					err_realloc=$(${bin_smartctl} -a ${current_drive} |egrep "(${s5_1}|${s5_2}|${s5_3})"|awk '{print $NF}')
					check_sattr "-i ${current_drive}"
				fi
			  else
				err_realloc="SMART_disabled"
			fi
		fi

		if [[ ${sctl} = "lsi" ]]; then current_drive=$(echo ${current_drive}|cut -d',' -f2); fi

		echo -n "drv:${current_drive}:"

		# Seagate health
		if [[ ${verification_type} = "SGT" ]]; then

			unset verification_type

			if [[ "${err_realloc}" = "SEAGATE:OK" ]] && [[ -z "${is_smart}" ]]; then
				echo -n "Health: OK (SMART Health status: ${err_realloc});"
			  else
			  	echo -n "Health: CRITICAL (SMART Health status: ${err_realloc});"
				let is_critical=1
			fi

		# PNY health
		  elif [[ ${verification_type} = "PNY" ]]; then

			unset verification_type

		  	if [[ ${err_realloc} -gt 0 ]] && [[ -z "${is_smart}" ]]; then
			  	echo -n "Health: OK (231 (Life Left %): ${err_realloc});"
			  else
			  	echo -n "Health: CRITICAL (231 (Life Left %): ${err_realloc});"
				let is_critical=1
			fi

		  else

			# Generic verification
			if [[ ! ${err_realloc} -gt ${max_realloc_cnt} ]] && [[ -z "${is_smart}" ]]; then
				echo -n "Health: OK (realloc: ${err_realloc});"
			  else
				echo -n "Health: CRITICAL (realloc: ${err_realloc});"
				let is_critical+=1
			fi
		fi
	done <<< "${drive_ids}"

	if [[ ${is_nvme} -eq 1 ]]; then

		if [[ ! -x ${bin_nvme} ]]; then
			echo "fatal: found NVMe storage but nvme tool not found on \$PATH, please install it, exiting" ; exit 2
		fi

		check_nvme
	fi
}

function check_sw_raid_if_found() {
	sw_arrays=$(grep -o "^md[_,a-z,0-9]*" /proc/mdstat|head -1)

	if [[ ! -z ${sw_arrays} ]]; then
		software_raid_check
	fi
}

function nagios_states() {
        # nagios states
	if [[ -z ${hw_errcnt} ]]; then hw_errcnt=0; fi
	if [[ -z ${sw_errcnt} ]]; then sw_errcnt=0; fi
	eall_cnt=$((hw_errcnt+sw_errcnt))

        if [[ ${is_critical} -gt 0 ]] || [[ ${hw_errcnt} -gt 0 ]]; then

		if [[ ${arg1} = "show_error_counters" ]]; then
			echo -e "\nnagios_status: ${STATE_CRITICAL}, hw_error_count: ${hw_errcnt}, sw_error_count: ${sw_errcnt}, all_errors: ${eall_cnt}"; fi
                exit ${STATE_CRITICAL}
          else
		if [[ ${arg1} = "show_error_counters" ]]; then
			echo -e "\nnagios_status: ${STATE_OK}, hw_error_count: ${hw_errcnt}, sw_error_count: ${sw_errcnt}, all_errors: ${eall_cnt}"; fi
                exit ${STATE_OK}
        fi
}

## Main ##

# sometimes non-root user's PATH is restricted to non-sbin dirs
# and the root's $PATH isn't exported when invoked via sudo
export PATH=$PATH:/sbin:/usr/sbin:/usr/local/sbin

bin_lspci=$(which 2>/dev/null lspci) bin_lsblk=$(which 2>/dev/null lsblk)
bin_zpool=$(which 2>/dev/null zpool) bin_nvme=$(which 2>/dev/null nvme)

max_realloc_cnt=49
max_media_err_cnt=49

if [[ ! -x ${bin_lspci} ]]; then
        echo "fatal: unable to find lspci tool on \$PATH, please install it, exiting" ; exit 2
fi

if [[ ! -x ${bin_lsblk} ]]; then
		#echo "fatal: unable to find lsblk tool on \$PATH, please install it, exiting" ; exit 2
		# there's number of problems with lsblk on centos 4/5, attempt to check manually if missing
		hw_nvme=$(for n in $(find /sys/block -maxdepth 1|grep /nvme); do basename ${n};done |grep -Pql "^nvme";echo $?)
fi

sw_arrays=$(grep -o "^md[_,a-z,0-9]*" /proc/mdstat)
bin_smartctl=$(which 2>/dev/null smartctl)
if [[ -z ${bin_smartctl} ]]; then
	echo "smartctl missing, exiting" ; exit 1
fi

# detect NVMe drives via lsblk
if [[ -x ${bin_lsblk} ]]; then
	hw_nvme=$(${bin_lsblk} -nd --output name|grep -Pql ^nvme;echo $?)
fi

if [[ ${hw_nvme} -eq 0 ]]; then
	is_nvme=1
fi

if [[ ! -z ${sw_arrays} ]]; then

	bin_mdadm=$(which 2>/dev/null mdadm)
	if [[ -z ${bin_mdadm} ]]; then
		echo "mdadm missing, exiting" ; exit 1
	fi
fi

hw_card_present=$(${bin_lspci} |grep "RAID"|grep Intel -v|wc -l)
arg1=$1
if [[ -z ${hw_errcnt} ]]; then hw_errcnt=0; fi
if [[ -z ${sw_errcnt} ]]; then sw_errcnt=0; fi

if [[ ${hw_card_present} -gt 0 ]]; then

	hw_card_model=$(${bin_lspci} |grep RAID|grep Intel -v|head -1|awk '{print $5}')

	if [[ ${hw_card_model} = "LSI" ]] || [[ ${hw_card_model} = "Broadcom" ]]; then
		lsi_hw_raid_check
		   hw_errcnt=${is_critical}
		# LSI on some hosts require '-d megaraid,N' for smartctl
		sctl=lsi
		check_sw_raid_if_found
		check_zfs_pools
		check_drives
		   sw_errcnt=${is_critical}
		nagios_states

	  elif [[ ${hw_card_model} = "Areca" ]]; then
		# different SMART output format
		sctl=Areca
		areca_hw_raid_check
		   hw_errcnt=${is_critical}
		check_sw_raid_if_found
		check_zfs_pools
		check_drives
		   sw_errcnt=${is_critical}
		nagios_states

	  elif [[ ${hw_card_model} = "3ware" ]]; then
		3ware_hw_raid_check
		   hw_errcnt=${is_critical}

		# 3ware require '-d 3ware,N' for smartctl
		sctl=3ware
		check_sw_raid_if_found
		check_zfs_pools
		check_drives
		   sw_errcnt=${is_critical}
		nagios_states

	  elif [[ ${hw_card_model} = "Adaptec" ]]; then

		bin_p2g=$(which 2>/dev/null pcre2grep)
		if [[ ! -x ${bin_p2g} ]]; then
		        echo "fatal: unable to find pcre2grep tool on \$PATH, please install it, exiting" ; exit 2
		  else
			adaptec_hw_raid_check
			   hw_errcnt=${is_critical}
			check_sw_raid_if_found
			check_zfs_pools
			check_drives
			   sw_errcnt=${is_critical}
			nagios_states
		fi

	  else  echo -n "[HWR]:Found unsupported RAID card ;; "
		check_sw_raid_if_found
		check_zfs_pools
		check_drives
		   sw_errcnt=${is_critical}
		nagios_states

	fi
  else
	# drive checks has been separated from software_raid_check() and check_drives() created instead
	# for drive checks on non-RAID setups
	check_sw_raid_if_found
	if [[ -z ${is_critical} ]]; then is_critical=0 ; fi
	check_zfs_pools
	check_drives
	  sw_errcnt=${is_critical}
	nagios_states
fi
