#!/bin/bash

### Global Variables ###
SSH=/usr/bin/ssh ###previously /bin/ssh
userName=ansible
isilonSSHkey="~/playarea/Isilon/IsilonSSH/id_rsa_isilon82"

checkSMBsync() {

	### Debug ###
	### set -x ###

	IsilonPRODshares=$(${SSH} -i ${isilonSSHkey} ${userName}@${isilonPROD} "isi smb shares list --format csv --no-header --no-footer")
	IsilonDRshares=$(${SSH} -i ${isilonSSHkey} ${userName}@${isilonDR} "isi smb shares list --format csv --no-header --no-footer")

	#### Get list of Isilon production shares from DR, existing and missing ####
	IFS=$'\n'
	for prodShares in `echo -e "${IsilonPRODshares}"`; do
	
		### Check for share on DR isilon ###
		foundShare=false
		for drShares in `echo -e "${IsilonDRshares}"`; do
			if [ ${prodShares} = "${drShares}" ];then
				foundShare=true
			fi
		done 

		if [ ${foundShare} = "true" ]; then
			existingShares="${prodShares}:${existingShares}"
			FOUND=true
		else	
			missingShares="${prodShares}:${missingShares}"
			FOUNDmissing=true
		fi

	done

	if [ ${FOUND}  = "true" ]; then
		echo "EXISTING:${existingShares}" | sed 's/:$//'
	fi
	if [ ${FOUNDmissing}  = "true" ]; then
		echo "MISSING:${missingShares}" | sed 's/:$//'
	fi
}


createSMBshare() {

	### Debug ###
	##set -x

	##### Create missing Prod share on DR #####

	IFS=$'\n'
	for createShare in `echo -e "${missingShares}"`; do

		echo "${createShare}"
		shareName=$(echo "${createShare}" | cut -d',' -f1)
		sharePath=$(echo "${createShare}" | cut -d',' -f2)
		echo "ssh ${userName}@${isilonDR} \"isi smb shares create \"${shareName}\" \"${sharePath}\" --create-path"
		${SSH} -i ${isilonSSHkey} ${userName}@${isilonDR} "isi smb shares create \"${shareName}\" \"${sharePath}\" --create-path ;  isi smb shares permission delete \"${shareName}\" --wellknown Everyone -f"

	done
}


applySMBperm() {

	### Debug ###
	###set -x

	##### Compare Existing DR Share Permissions with production and fix #####
	IFS=$'\n'
	for comparePerm in `echo -e ${existingShares} | cut -d',' -f1- | sed 's/,/\n/g' | sed 's/^\/.*[:]//g' | grep -v "^/"`; do
		prodSharePerm=$(${SSH} -i ${isilonSSHkey} ${userName}@${isilonPROD} "isi smb shares permission list \"${comparePerm}\" --format csv --no-header --no-footer")	
		drSharePerm=$(${SSH} -i ${isilonSSHkey} ${userName}@${isilonDR} "isi smb shares permission list \"${comparePerm}\" --format csv --no-header --no-footer")
	
		for crossCheck in `echo "${prodSharePerm}"`; do
			FOUNDperm="false"
			COUNT=1
		
			for DRpermission in `echo "${drSharePerm}"`; do
				#echo $COUNT
				((COUNT=${COUNT}+1))
				#echo "THIS IS CROSSCHECK::::> ${crossCheck}"	
				#echo "THIS IS DRPERMISSION::::> ${DRpermission}"	
				if [[ "${crossCheck}" = "${DRpermission}" ]]; then
					FOUNDperm="true"
					break
				fi
			done
		
			if [[ $FOUNDperm = "false" ]]; then
				echo "-------------------------"; 
				echo "**WARN** DR Share \"${comparePerm}\" out of sync with Production"
				echo -e "Missing share permission: \c"
				missingPerm=$(echo "${crossCheck}")
				echo "${missingPerm}"
				echo "FIXING - Adding missing share permission"

				for applyMissingPerm in `echo "${missingPerm}"`; do
					accountShare=$(echo ${applyMissingPerm} | cut -d',' -f1 | tr -d '"')
					accountType=$(echo ${applyMissingPerm} | cut -d',' -f2)
					accountRoot=$(echo ${applyMissingPerm} | cut -d',' -f3)
					accountPermType=$(echo ${applyMissingPerm} | cut -d',' -f4)
					accountPerm=$(echo ${applyMissingPerm} | cut -d',' -f5)

					case $accountType in
						group) cmdType="--group" ;;
						uid) cmdType="--uid" ;;
						gid) cmdType="--gid" ;;
						sid) cmdType="--sid" ;;
						wellknown) cmdType="--wellknown" ;;
						*) cmdType="" ;;
					esac
	
					if [[ $accountRoot != "False" ]]; then
						cmdRoot="--run-as-root"
					else
						cmdRoot=""
					fi
			
					echo "ssh ${userName}@${isilonDR} \"isi smb shares permission create \"${comparePerm}\" ${cmdType} \"${accountShare}\" -d ${accountPermType} -p ${accountPerm} ${cmdRoot}\""
					${SSH} -i ${isilonSSHkey} ${userName}@${isilonDR} "isi smb shares permission create \"${comparePerm}\" ${cmdType} \"${accountShare}\" -d ${accountPermType} -p ${accountPerm} ${cmdRoot}"
				done
			fi	
		
		done
	done
}


####### MAIN #######

case ${1} in
	check) 
		### Variables ###
		isilonPROD=${2}
		isilonDR=${3}
		existingShares=""
		missingShares=""
		FOUNDshare=false
		FOUNDmissing=false
		checkSMBsync ;;
	create)
		### Variables ###
		isilonPROD=${2}
		isilonDR=${3}
		missingShares=$(echo -e "${4}" | tr -d '\"][\\' | sed -e 's/ MISSING:/\nMISSING:/g' | grep "^MISSING:")
		missingShares=$(echo "${missingShares}" | sed 's/:/\n/g' | grep -v ^MISSING)
		createSMBshare
		;;
	perm)
		### Variables ###
		isilonPROD=${2}
		isilonDR=${3}
		existingShares=$(echo -e "${4}" | tr -d '\"][\\' | sed -e 's/ MISSING:/\nMISSING:/g' |  grep "^EXISTING:" | sed -e 's/^EXISTING://')
		applySMBperm
		;;
	*)
		echo "incorrect syntax" ;;
esac
