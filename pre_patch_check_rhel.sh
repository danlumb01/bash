#!/bin/bash

# --- Function to make logging less messy
function timeStamp {
	date +"%T"
}

function prePatchChecks {
	# --- Check disk space on core file systems
	dirs="/var /usr /tmp"
	for d in $dirs ; do
		percentUsed=$(df -lP $d | grep $d | awk {'print $5'} | cut -d '%' -f1)
		if [[ $percentUsed -gt 90 ]] ; then
			echo "$(timeStamp) - Disk space in $d 90% utilised - FAIL"
			diskOk="no"
		else
			echo "$(timeStamp) - Disk space adequate in $d - PASS"
			diskOk="yes"
		fi
	done

	echo "$(timeStamp) - Performing a check on /boot file space..."
	bootUsed=$(df | grep "boot" |awk {'print $3'})
	bootAvail=$(df | grep "boot" |awk {'print $4'})
	# --- 50MB in KB - amount of space required (roughly)
	safeLimit=51200;

	if [[ $bootAvail -lt $safeLimit ]] ; then
		# --- Attempt some package cleanup
		echo "$(timeStamp) - /boot space less that 50MB - FAIL"
		bootOk="no"
	else
		echo "$(timeStamp) - Adequate space in /boot - $(($bootAvail/1024))MB - PASS"
		bootOk="yes"
	fi


	# --- Check that the system is subscribed correctly
	if subscription-manager identity | grep rhel > /dev/null 2>&1 ; then
		echo "$(timeStamp) - Active RHEL6 subscription detected - PASS"
		subOk="yes"
	else
		echo "$(timeStamp) - Cannot find an active RHEL6 subscription - FAIL"
		subOk="no"
	fi

	# --- Check that there are yum updates actually available
	yum -q check-update > /dev/null 2>&1
	yumStatus=$?

	case $yumStatus in
		100)
		echo "$(timeStamp) - There are updates ready to be installed via yum - PASS"
		yumOk="yes"
		;;
		0)
		echo "$(timeStamp) - yum is working correctly but there are no updates outstanding - PASS"
		yumOk="yes"
		;;
		*)
		echo "$(timeStamp) - yum doesn't appear to be working correctly - FAIL"
		yumOk="no"
		;;
	esac

}


function decideExit {
	# --- Decide based on the results how to exit (for the purposes of making results easier to find in Satellite)
	if [[ $diskOk == "yes" ]] && [[ $bootOk == "yes" ]] && [[ $subOk == "yes" ]] && [[ $yumOk == "yes" ]] ; then
		# --- All is well, mark the result in Satellite as successful
		echo "Exited with 0"
		exit 0
	else
		# --- Something failed, mark the result in Satellite as failed
		echo "Exited with 1"
		exit 1
	fi
}

prePatchChecks
decideExit
