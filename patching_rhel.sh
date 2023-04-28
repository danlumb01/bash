#!/bin/bash

#############################################################
# --- RHEL Patching script
# -- Features:
# - Checks for obvious problems with disk space (Could be later improved with yum "update --assumeno" to find update sizes)
# - Checks that updates are actually available
# - Checks status of the servers content subscriptions
# - Creates record of existing packages
# - Archives all of /etc and stores in /tmp in case a new package botches some old config
# - Patches the server (Optionally the Kernel)
# - Optionally reboots
#
#
#
#  RUN WITH 'TEE' IF YOU WANT A PERSISTENT LOG.  E.g. - "./patching.sh --nokernel --noreboot | tee /tmp/patchingLog.txt"
#
#
#


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
			echo "$(timeStamp) - Disk is above 90% utilised - Exiting"
			exit 1
		else
			echo "$(timeStamp) - Disk space adequate in $d - Continuing"
		fi
	done

	echo "$(timeStamp) - Performing a check on /boot file space..."
	bootUsed=$(df | grep "boot" |awk {'print $3'})
	bootAvail=$(df | grep "boot" |awk {'print $4'})
	# --- 50MB in KB - amount of space required (roughly)
	safeLimit=51200;

	if [[ $bootAvail -lt $safeLimit ]] ; then
		# --- Attempt some package cleanup
		echo "$(timeStamp) - /boot space less than 50MB, attempting a clean up of old Kernels..."
		package-cleanup --oldkernels --count=2 -q -y
	else
		echo "$(timeStamp) - Adequate space in /boot - $(($bootAvail/1024))MB"
	fi


	# --- Check that the system is subscribed correctly
	if subscription-manager identity | grep -E rhel${majVer} > /dev/null 2>&1 ; then
		echo "$(timeStamp) - Active RHEL subscription detected - Continuing"
	else
		echo "$(timeStamp) - Cannot find an active RHEL subscription - Exiting"
		exit 1
	fi

	# --- Check that there are yum updates actually available
	yum -q check-update > /dev/null 2>&1
	yumStatus=$?

	case $yumStatus in
		100)
		echo "$(timeStamp) - There are updates ready to be installed via yum - Continuing"
		;;
		0)
		echo "$(timeStamp) - yum is working correctly but there are no updates outstanding - Continuing"
		;;
		*)
		echo "$(timeStamp) - yum doesn't appear to be working correctly - Exiting"
		exit 1
		;;
	esac


}


function rpmBackup {
	# --- Create a copy of the rpm package list and /etc directory at this point in time for historical and rollback purposes
	rpmFile="/tmp/$(date +"%m-%d-%Y")-rpmBackup.txt"
	tarFile="/tmp/$(date +"%m-%d-%Y")-configBackup.tar.gz"
	echo "$(timeStamp) - Creating the rpm backup file at $rpmFile"
	rpm -q -a --queryformat '%{INSTALLTIME} %{NAME}-%{VERSION}-%{RELEASE}\n' | sort -n >> $rpmFile
	# --- Create a copy of /etc directory to preserve any config that could potentially be lost
	echo "$(timeStamp) - Creating an archive of /etc at $tarFile"
	tar -czf $tarFile /etc > /dev/null 2>&1
}


function vmTools {
	# --- Determine what kind of VMware tools is running
	if [[ -f /etc/vmware-tools/services.sh ]] ; then
		echo "$(timeStamp) - This server is using the proprietary VMware tools"
		tools="prop"
	elif rpm -qa | grep "open-vm-tools" > /dev/null 2>&1 ; then
		echo "$(timeStamp) - This server is already using the open-vm-tools - Skipping tools install"
		tools="open"
	else
		echo "$(timeStamp) - Cannot find a valid VM tools installation (open-vm or vmware)"
		tools="null"
	fi

	# --- Take the appropriate action
	if [[ $tools == "prop" ]] ; then
		echo "$(timeStamp) - Uninstalling existing proprietary VMware tools and performing some cleanup..."
		/usr/bin/vmware-uninstall-tools.pl > /dev/null 2>&1
		rm -rf /etc/vmware-tools
		rm -rf /usr/lib/vmware-tools/
		echo "$(timeStamp) - Enabling extra repositories containing open-vm-tools..."
		subscription-manager repos --enable EMA_EPEL_epel_${majVer}_x86_64 > /dev/null 2>&1
		yum check-update -q > /dev/null 2>&1
		echo "$(timeStamp) - Installing open-vm-tools package..."
		yum install -q -y open-vm-tools
		# --- Use new systemd startup if running on RHEL 7 
		if [[ $majVer -eq 6 ]] ; then
			service vmtoolsd restart
		else
			/usr/bin/systemctl restart vmtoolsd.service
		fi
		
		if [[ $? -eq 0 ]] ; then
		echo "$(timeStamp) - Installation of open-vm-tools successful :)"
			vmHardware="ready"
		else
			echo "$(timeStamp) - Cannot start open-vm-tools. Is the package installed correctly?"
			vmHardware="notready"
		fi
	fi
}

# --- Update the packages and the kernel
function yumUpdateFull {
	yum -q clean all
	echo "$(timeStamp) - Updating Kernel..."
	yum -q -y --disableexcludes=all update kernel*
	echo "$(timeStamp) - Updating packages..."
	yum -q -y --disableexcludes=all update
}

# --- Update only the packages, no kernel
function yumUpdatePackageOnly {
	echo "$(timeStamp) - Updating packages..."
	yum -q clean all
	yum -q -y update
}

# --- Check for presence of duplicate
function dupeCheck {
  if rpm -qa | grep yum-utils > /dev/null 2>&1 ; then
    echo "$(timeStamp) - Performing a check for duplicates in rpm DB..."
    duplicatePackages=$(package-cleanup --dupes | egrep "x86_64"\|"noarch")
    if [[ $? -eq 0 ]] ; then
      echo "$(timeStamp) - Duplicate packages found in RPM Database:"
      dupes=0
      for duplicate in $duplicatePackages ; do
        echo $duplicate
      done
    else
      echo "$(timeStamp) - No duplicate packages found in RPM database :)"
      dupes=1
    fi
  else
    echo "$(timeStamp) - Package 'yum-utils is missing, can't check for duplicates..."
  fi
}


# --- Clean up duplicates if they were found in func "dupeCheck{}"
function dupeClean {
	if [[ $dupes -eq 0 ]] ; then
		echo "$(timeStamp) - Removing duplicate packages..."
		package-cleanup -y --cleandupes > /dev/null 2>&1
		if [[ $? -eq 0 ]] ; then
			echo "$(timeStamp) - Duplicates removed successfully"
			yum-complete-transaction --cleanup-only > /dev/null 2&>1
		else
			echo "$(timeStamp) - Issues removing duplicates... Please investigate manually..."
		fi
	else
		echo "$(timeStamp) - No duplicate packages to be removed, continuing..."
	fi
}

# --- Parse the arguments
if [[ "$#" -ne 2 ]] ; then
	echo "Incorrect number of arguments provided."
	echo "Usage: $0 [--kernel/nokernel] [--reboot/noreboot]"
	exit 1
fi

while test -n "$1" ; do
	case "$1" in
		--kernel)
		kernUpdate="true"
		shift
		;;
		--nokernel)
		kernUpdate="false"
		shift
		;;
		--reboot)
		reboot="true"
		shift
		;;
		--noreboot)
		reboot="false"
		shift
		;;
		*)
		echo "Usage: $0 [--kernel/nokernel] [--reboot/noreboot]"
		exit 1
		;;
	esac
done

# --- Clear the screen
clear

# --- Work out RHEL major version
majVer=$(sed 's/[^0-9]*\([0-9]\).*/\1/' /etc/redhat-release)

# --- Info
echo " -------------------- RHEL Patching script - $0"
echo "You have passed the following arguments:"
echo "Patch the Kernel: $kernUpdate"
echo "Reboot automatically: $reboot"
echo "Hostname:" `hostname`
echo "Version: $(cat /etc/redhat-release)"
echo "Time started: $(date +"%m-%d-%Y"\ "%T")"
echo



# --- Main function calls
if [[ $kernUpdate == true ]] ; then
	prePatchChecks
	rpmBackup
	vmTools
	yumUpdateFull
	dupeCheck
	dupeClean
elif [[ $kernUpdate == false ]] ; then
	prePatchChecks
	rpmBackup
	vmTools
	yumUpdatePackageOnly
	dupeCheck
	dupeClean
else
	# Somehow the value got butchered, safer to just fail
	echo "$(timeStamp) - Something very strange happened with the arguments - Exiting"
	exit 1
fi


# --- Reboot decision
if [[ $reboot == true ]] ; then
	echo "$(timeStamp) - Script complete!"
	echo "$(timeStamp) - Server going for reboot"
	shutdown -r now
else
	echo "$(timeStamp) - Script complete!"
	echo "$(timeStamp) - Please reboot manually at a suitable time"
fi




### - End
