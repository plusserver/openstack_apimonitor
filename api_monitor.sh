#!/bin/bash
# api_monitor.sh
# 
# Test script testing the reliability and performance of OpenStack API
# It works by doing a real scenario test: Setting up a real environment
# With routers, nets, jumphosts, disks, VMs, ...
# 
# We collect statistics on API call performance as well as on resource
# creation times.
# Failures are noted and alarms are generated.
#
# Status:
# - Errors not yet handled everywhere
# - Live Volume and NIC attachment not yet implemented
# - Log too verbose for permament operation ...
#
# (c) Kurt Garloff <kurt.garloff@t-systems.com>, 2/2017-7/2017
# License: CC-BY-SA (2.0)
#
# General approach:
# - create router (VPC)
# - create 1+$NONETS (1+2) nets -- $NONETS is normally the # of AZs
# - create 1+$NONETS subnets
# - create security groups
# - create virtual IP (for outbound SNAT via JumpHosts)
# - create SSH keys
# - create $NOAZS JumpHost VMs by
#   a) creating disks (from image)
#   b) creating ports
#   c) creating VMs
# - associating a floating IP to each Jumphost
# - configuring the virtIP as default route
# - JumpHosts do SNAT for outbound traffic and port forwarding for inbound
#   (this requires SUSE images with SFW2-snat package to work)
# - create N internal VMs striped over the nets and AZs by
#   a) creating disks (from image) -- if option -d is not used
#   b) creating a port -- if option -P is not used
#   c) creating VM (from volume or from image, dep. on -d)
#   (Steps a and c take long, so we do many in parallel and poll for progress)
#   d) do some property changes to VMs
# - after everything is complete, we wait for the VMs to be up
# - we ping them, log in via ssh and see whether they can ping to the outside world (quad9)
# - NOT YET: attach an additional disk
# - NOT YET: attach an additional NIC
# 
# - Finally, we clean up ev'thing in reverse order
#   (We have kept track of resources to clean up.
#    We can also identify them by name, which helps if we got interrupted, or
#    some cleanup action failed.)
#
# So we end up testing: Router, incl. default route (for SNAT instance),
#  networks, subnets, and virtual IP, security groups and floating IPs,
#  volume creation from image, deletion after VM destruction
#  VM creation from bootable volume (and from image if -d is given)
#  Metadata service (without it ssh key injection fails of course)
#  Images (we use openSUSE for the jumphost for SNAT/port-fwd and CentOS7 by dflt for VMs)
#  Waiting for volumes and VMs
#  Destroying all of these resources again
#
# We do some statistics on the duration of the steps (min, avg, median, 95% quantile, max)
# We of course also note any errors and timeouts and report these, optionally sending
#  email of SMN alarms.
#
# This takes rather long, as typical API calls take b/w 1 and 2s on OTC
# (including the round trip to keystone for the token).
#
# Optimization possibilities:
# - Cache token and reuse when creating a large number of resources in a loop
#
# Prerequisites:
# - Working python-XXXclient tools (glance, neutron, nova, cinder)
# - otc.sh from otc-tools (for optional SMN -m and project creation -p)
# - sendmail (if email notification is requested)
#
# Example:
# Run 100 loops deploying (and deleting) 2+8 VMs (including nets, volumes etc.),
# with daily statistics sent to SMN...API-Notes and Alarms to SMN...APIMonitor
# ./api_monitor.sh -n 8 -s -m urn:smn:eu-de:0ee085d22f6a413293a2c37aaa1f96fe:APIMon-Notes -m urn:smn:eu-de:0ee085d22f6a413293a2c37aaa1f96fe:APIMonitor -i 100

VERSION=1.34

# User settings
#if test -z "$PINGTARGET"; then PINGTARGET=f-ed2-i.F.DE.NET.DTAG.DE; fi
if test -z "$PINGTARGET"; then PINGTARGET=dns.quad9.net; fi
if test -z "$PINGTARGET2"; then PINGTARGET2=google-public-dns-b.google.com; fi

# Prefix for test resources
FORCEDEL=NONONO
if test -z "$RPRE"; then RPRE="APIMonitor_$$_"; fi
SHORT_DOMAIN="${OS_USER_DOMAIN_NAME##*OTC*00000000001000}"
ALARMPRE="${SHORT_DOMAIN:3:3}/${OS_PROJECT_NAME#*_}"
SHORT_DOMAIN=${SHORT_DOMAIN:-$OS_PROJECT_NAME}
GRAFANANM=api-monitoring

# Number of VMs and networks
AZS=$(nova availability-zone-list 2>/dev/null| grep -v '\-\-\-' | grep -v '| Name' | sed 's/^| \([^ ]*\) *.*$/\1/')
if test -z "$AZS"; then AZS=(eu-de-01 eu-de-02);
else AZS=($AZS); fi
#echo "${#AZS[*]} AZs: ${AZS[*]}"
NOAZS=${#AZS[*]}
NOVMS=12
NONETS=$NOAZS
MANUALPORTSETUP=1
if [[ $OS_AUTH_URL == *otc*t-systems.com* ]]; then
  NAMESERVER=${NAMESERVER:-100.125.4.25}
fi

MAXITER=-1

ERRWAIT=1
VMERRWAIT=2

# API timeouts
NETTIMEOUT=16
FIPTIMEOUT=32
NOVATIMEOUT=24
NOVABOOTTIMEOUT=48
CINDERTIMEOUT=20
GLANCETIMEOUT=32
DEFTIMEOUT=16

REFRESHPRJ=0

echo "Running api_monitor.sh v$VERSION"
if test "$1" != "CLEANUP"; then echo "Using $RPRE prefix for resrcs on $OS_USER_DOMAIN_NAME/$OS_PROJECT_NAME (${AZS[*]})"; fi

# Images, flavors, disk sizes
JHIMG="${JHIMG:-Standard_openSUSE_42_JeOS_latest}"
JHIMGFILT="${JHIMGFILT:---property-filter __platform=OpenSUSE}"
IMG="${IMG:-Standard_CentOS_7_latest}"
IMGFILT="${IMGFILT:---property-filter __platform=CentOS}"
JHFLAVOR=${JHFLAVOR:-computev1-1}
FLAVOR=${FLAVOR:-s2.medium.1}

if [[ "$JHIMG" != *openSUSE* ]]; then
	echo "WARN: Need openSUSE_42 als JumpHost for port forwarding via user_data" 1>&2
	exit 1
fi

# Optionally increase JH and VM volume sizes beyond image size
# (slows things down due to preventing quick_start and growpart)
ADDJHVOLSIZE=${ADDJHVOLSIZE:-0}
ADDVMVOLSIZE=${ADDVMVOLSIZE:-0}

DATE=`date +%s`
LOGFILE=$RPRE$DATE.log
declare -i APIERRORS=0
declare -i APITIMEOUTS=0
declare -i APICALLS=0

# Nothing to change below here
BOLD="\e[0;1m"
REV="\e[0;3m"
NORM="\e[0;0m"
RED="\e[0;31m"
GREEN="\e[0;32m"
YELLOW="\e[0;33m"

usage()
{
  #echo "Usage: api_monitor.sh [-n NUMVM] [-l LOGFILE] [-p] CLEANUP|DEPLOY"
  echo "Usage: api_monitor.sh [options]"
  echo " -n N   number of VMs to create (beyond 2 JumpHosts, def: 12)"
  echo " -N N   number of networks/subnets/jumphosts to create (def: # AZs)"
  echo " -l LOGFILE record all command in LOGFILE"
  echo " -e ADR sets eMail address for notes/alarms (assumes working MTA)"
  echo "         second -e splits eMails; notes go to first, alarms to second eMail"
  echo " -m URN sets notes/alarms by SMN (pass URN of queue)"
  echo "         second -m splits notifications; notes to first, alarms to second URN"
  echo " -s     sends stats as well once per day, not just alarms"
  echo " -S [NM] sends stats to grafana via local telegraf http_listener (def for NM=api-monitoring)"
  echo " -d     boot Directly from image (not via volume)"
  echo " -P     do not create Port before VM creation"
  echo " -D     create all VMs with one API call (implies -d -P)"
  echo " -i N   sets max number of iterations (def = -1 = inf)"
  echo " -g N   increase VM volume size by N GB"
  echo " -G N   increase JH volume size by N GB"
  echo " -w N   sets error wait (API, VM): 0-inf seconds or neg value for interactive wait"
  echo " -W N   sets error wait (VM only): 0-inf seconds or neg value for interactive wait"
  echo " -p N   use a new project every N iterations"
  echo " -c     noColors: don't use bold/red/... ASCII sequences"
  echo "Or: api_monitor.sh [-f] CLEANUP XXX to clean up all resources with prefix XXX"
  exit 0
}

while test -n "$1"; do
  case $1 in
    "-n") NOVMS=$2; shift;;
    "-n"*) NOVMS=${1:2};;
    "-N") NONETS=$2; shift;;
    "-l") LOGFILE=$2; shift;;
    "help"|"-h"|"--help") usage;;
    "-s") SENDSTATS=1;;
    "-S") GRAFANA=1;
	if test -n "$2" -a "$2" != "CLEANUP" -a "$2" != "DEPLOY" -a "${2:0:1}" != "-"; then GRAFANANM="$2"; shift; fi;;
    "-P") unset MANUALPORTSETUP;;
    "-d") BOOTFROMIMAGE=1;;
    "-D") BOOTALLATONCE=1; BOOTFROMIMAGE=1; unset MANUALPORTSETUP;;
    "-e") if test -z "$EMAIL"; then EMAIL="$2"; else EMAIL2="$2"; fi; shift;;
    "-m") if test -z "$SMNID"; then SMNID="$2"; else SMNID2="$2"; fi; shift;;
    "-i") MAXITER=$2; shift;;
    "-g") ADDVMVOLSIZE=$2; shift;;
    "-G") ADDJHVOLSIZE=$2; shift;;
    "-w") ERRWAIT=$2; shift;;
    "-W") VMERRWAIT=$2; shift;;
    "-f") FORCEDEL=XDELX;;
    "-p") REFRESHPRJ=$2; shift;;
    "-c") NOCOL=1;;
    "CLEANUP") break;;
    *) echo "Unknown argument \"$1\""; exit 1;;
  esac
  shift
done


# Test precondition
type -p nova >/dev/null 2>&1
if test $? != 0; then
  echo "Need nova installed"
  exit 1
fi

type -p otc.sh >/dev/null 2>&1
if test $? != 0 -a -n "$SMNID"; then
  echo "Need otc.sh for SMN notifications"
  exit 1
fi

test -x /usr/sbin/sendmail
if test $? != 0 -a -n "$EMAIL"; then
  echo "Need /usr/sbin/sendmail for email notifications"
  exit 1
fi

if test -z "$OS_USERNAME"; then
  echo "source OS_ settings file before running this test"
  exit 1
fi

if ! neutron router-list >/dev/null; then
  echo "neutron call failed, exit"
  exit 2
fi

if test "$NOCOL" == "1"; then
  BOLD="**"
  REV="__"
  NORM=" "
  RED="!!"
  GREEN="++"
  YELLOW=".."
fi

# Alarm notification
# $1 => return code
# $2 => invoked command
# $3 => command output
# $4 => timeout (for rc=137)
sendalarm()
{
  local PRE RES RM URN TOMSG
  local RECEIVER_LIST RECEIVER
  DATE=$(date)
  if test $1 = 0; then
    PRE="Note"
    RES=""
    echo -e "$BOLD$PRE on $ALARMPRE/${RPRE%_} on $(hostname): $2\n$DATE\n$3$NORM" 1>&2
  elif test $1 -gt 128; then
    PRE="TIMEOUT $4"
    RES=" => $1"
    echo -e "$RED$PRE on $ALARMPRE/${RPRE%_} on $(hostname): $2\n$DATE\n$3$NORM" 1>&2
  else
    PRE="ALARM $1"
    RES=" => $1"
    echo -e "$RED$PRE on $ALARMPRE/${RPRE%_} on $(hostname): $2\n$DATE\n$3$NORM" 1>&2
  fi
  TOMSG=""
  if test "$4" != "0" -a $1 != 0; then
    TOMSG="(Timeout: ${4}s)"
  fi
  if test $1 != 0; then
    RECEIVER_LIST=("${ALARM_EMAIL_ADDRESSES[@]}")
  else
    RECEIVER_LIST=("${NOTE_EMAIL_ADDRESSES[@]}")
  fi
  if test -n "$EMAIL"; then
    if test -n "$EMAIL2" -a $1 != 0; then EM="$EMAIL2"; else EM="$EMAIL"; fi
    RECEIVER_LIST=("$EM" "${RECEIVER_LIST[@]}")
  fi
  FROM="$LOGNAME@$(hostname -f)"
  for RECEIVER in "${RECEIVER_LIST[@]}"
  do
    echo "From: ${RPRE%_} $(hostname) <$FROM>
To: $RECEIVER
Subject: $PRE on $ALARMPRE: $2
Date: $(date -R)

$PRE on $SHORT_DOMAIN/$OS_PROJECT_NAME

${RPRE%_} on $(hostname):
$2
$3
$TOMSG" | /usr/sbin/sendmail -t -f $FROM
  done
  if test $1 != 0; then
    RECEIVER_LIST=("${ALARM_MOBILE_NUMBERS[@]}")
  else
    RECEIVER_LIST=("${NOTE_MOBILE_NUMBERS[@]}")
  fi
  if test -n "$SMNID"; then
    if test -n "$SMNID2" -a $1 != 0; then URN="$SMNID2"; else URN="$SMNID"; fi
    RECEIVER_LIST=("$URN" "${RECEIVER_LIST[@]}")
  fi
  for RECEIVER in "${RECEIVER_LIST[@]}"
  do
    echo "$PRE on $SHORT_DOMAIN/$OS_PROJECT_NAME: $DATE
${RPRE%_} on $(hostname):
$2
$3
$TOMSG" | otc.sh notifications publish $RECEIVER "$PRE from $(hostname)/$ALARMPRE"
  done
}

rc2bin()
{
  if test $1 = 0; then echo 0; return 0; else echo 1; return 1; fi
}

# Map return code to 2 (timeout), 1 (error), or 0 (success) for Grafana
# $1 => input (RC), returns global var GRC
rc2grafana()
{
  if test $1 == 0; then GRC=0; elif test $1 -ge 128; then GRC=2; else GRC=1; fi
}

updAPIerr()
{
  let APIERRORS+=$(rc2bin $1);
  if test $1 -ge 129; then let APITIMEOUTS+=1; fi
}

declare -i EXITED=0
exithandler()
{
  loop=$(($MAXITER-1))
  if test "$EXITED" = "0"; then
    echo -e "\n${REV}SIGINT received, exiting after this iteration$NORM"
  elif test "$EXITED" = "1"; then
    echo -e "\n$BOLD OK, cleaning up right away $NORM"
    FORCEDEL=NONONO
    cleanup
    if test "$REFRESHPRJ" != 0; then cleanprj; fi
    kill -TERM 0
  else
    echo -e "\n$RED OK, OK, exiting without cleanup. Use api_monitor.sh CLEANUP $RPRE to do so.$NORM"
    if test "$REFESHPRJ" != 0; then echo -e "${RED}export OS_PROJECT_NAME=$OS_PROJECT_NAME before doing so$NORM"; fi
    kill -TERM 0
  fi
  let EXITED+=1
}

errwait()
{
  if test $1 -lt 0; then
    local ans
    echo -en "${YELLOW}ERROR: Hit Enter to continue: $NORM"
    read ans
  else
    sleep $1
  fi
}


trap exithandler SIGINT

# Timeout killer
# $1 => PID to kill
# $2 => timeout
# waits $2, sends QUIT, 1s, HUP, 1s, KILL
killin()
{
  sleep $2
  test -d /proc/$1 || return 0
  kill -SIGQUIT $1
  sleep 1
  kill -SIGHUP $1
  sleep 1	
  kill -SIGKILL $1
}

# Command wrapper for openstack list commands
# $1 = search term
# $2 = timeout (in s)
# $3-oo => command
ostackcmd_search()
{
  local SEARCH=$1; shift
  local TIMEOUT=$1; shift
  local LSTART=$(date +%s.%3N)
  if test "$TIMEOUT" = "0"; then
    RESP=$($@ 2>&1)
  else
    RESP=$($@ 2>&1 & TPID=$!; killin $TPID $TIMEOUT >/dev/null 2>&1 & KPID=$!; wait $TPID; RC=$?; kill $KPID; exit $RC)
  fi
  local RC=$?
  local LEND=$(date +%s.%3N)
  ID=$(echo "$RESP" | grep "$SEARCH" | head -n1 | sed -e 's/^| *\([^ ]*\) *|.*$/\1/')
  echo "$LSTART/$LEND/$SEARCH: $@ => $RC $RESP $ID" >> $LOGFILE
  if test $RC != 0 -a -z "$IGNORE_ERRORS"; then
    sendalarm $RC "$*" "$RESP" $TIMEOUT
    errwait $ERRWAIT
  fi
  local TIM=$(python -c "print \"%.2f\" % ($LEND-$LSTART)")
  if test "$RC" != "0"; then echo "$TIM $RC"; echo -e "${YELLOW}ERROR: $@ => $RC $RESP$NORM" 1>&2; return $RC; fi
  if test -z "$ID"; then echo "$TIM $RC"; echo -e "${YELLOW}ERROR: $@ => $RC $RESP => $SEARCH not found$NORM" 1>&2; return $RC; fi
  echo "$TIM $ID"
  return $RC
}

# Command wrapper for openstack commands
# Collecting timing, logging, and extracting id
# $1 = id to extract
# $2 = timeout (in s)
# $3-oo => command
ostackcmd_id()
{
  local IDNM=$1; shift
  local TIMEOUT=$1; shift
  local LSTART=$(date +%s.%3N)
  if test "$TIMEOUT" = "0"; then
    RESP=$($@ 2>&1)
  else
    RESP=$($@ 2>&1 & TPID=$!; killin $TPID $TIMEOUT >/dev/null 2>&1 & KPID=$!; wait $TPID; RC=$?; kill $KPID; exit $RC)
  fi
  local RC=$?
  local LEND=$(date +%s.%3N)
  local TIM=$(python -c "print \"%.2f\" % ($LEND-$LSTART)")

  test "$1" = "openstack" && shift
  if test -n "$GRAFANA"; then
      # log time / rc to grafana
      rc2grafana $RC
      curl -si -XPOST 'http://localhost:8186/write?db=cicd' --data-binary "$GRAFANANM,cmd=$1,method=$2 duration=$TIM,return_code=$GRC $(date +%s%N)" >/dev/null
  fi

  if test $RC != 0 -a -z "$IGNORE_ERRORS"; then
    sendalarm $RC "$*" "$RESP" $TIMEOUT
    errwait $ERRWAIT
  fi
  if test "$IDNM" = "DELETE"; then
    ID=$(echo "$RESP" | grep "^| *status *|" | sed -e "s/^| *status *| *\([^|]*\).*\$/\1/" -e 's/ *$//')
    echo "$LSTART/$LEND/$ID: $@ => $RC $RESP" >> $LOGFILE
  else
    ID=$(echo "$RESP" | grep "^| *$IDNM *|" | sed -e "s/^| *$IDNM *| *\([^|]*\).*\$/\1/" -e 's/ *$//')
    echo "$LSTART/$LEND/$ID: $@ => $RC $RESP" >> $LOGFILE
    if test "$RC" != "0"; then echo "$TIM $RC"; echo -e "${YELLOW}ERROR: $@ => $RC $RESP$NORM" 1>&2; return $RC; fi
  fi
  echo "$TIM $ID"
  return $RC
}

# Another variant -- return results in global variable OSTACKRESP
# Append timing to $1 array
# $2 = timeout (in s)
# $3-oo command
# DO NOT call this in a subshell
OSTACKRESP=""
ostackcmd_tm()
{
  local STATNM=$1; shift
  local TIMEOUT=$1; shift
  local LSTART=$(date +%s.%3N)
  # We can count here, as we are not in a subprocess
  let APICALLS+=1
  if test "$TIMEOUT" = "0"; then
    OSTACKRESP=$($@ 2>&1)
  else
    OSTACKRESP=$($@ 2>&1 & TPID=$!; killin $TPID $TIMEOUT >/dev/null 2>&1 & KPID=$!; wait $TPID; RC=$?; kill $KPID; exit $RC)
  fi
  local RC=$?
  if test $RC != 0 -a -z "$IGNORE_ERRORS"; then
    # We can count here, as we are not in a subprocess
    let APIERRORS+=1
    sendalarm $RC "$*" "$OSTACKRESP" $TIMEOUT
    errwait $ERRWAIT
  fi
  local LEND=$(date +%s.%3N)
  local TIM=$(python -c "print \"%.2f\" % ($LEND-$LSTART)")
  test "$1" = "openstack" && shift
  if test -n "$GRAFANA"; then
    # log time / rc to grafana telegraph
    rc2grafana $RC
    curl -si -XPOST 'http://localhost:8186/write?db=cicd' --data-binary "$GRAFANANM,cmd=$1,method=$2 duration=$TIM,return_code=$GRC $(date +%s%N)" >/dev/null
  fi
  eval "${STATNM}+=( $TIM )"
  echo "$LSTART/$LEND/: $@ => $OSTACKRESP" >> $LOGFILE
  return $RC
}

# Create a number of resources and keep track of them
# $1 => quantity of resources
# $2 => name of timing statistics array
# $3 => name of resource list array ("S" appended)
# $4 => name of resource array ("S" appended, use \$VAL to ref) (optional)
# $5 => dito, use \$MVAL (optional, use NONE if unneeded)
# $6 => name of array where we store the timestamp of the operation (opt)
# $7 => id field from resource to be used for storing in $3
# $8 => timeout
# $9- > openstack command to be called
#
# In the command you can reference \$AZ (1 or 2), \$no (running number)
# and \$VAL and \$MVAL (from $4 and $5).
#
# NUMBER STATNM RSRCNM OTHRSRC MORERSRC STIME IDNM COMMAND
createResources()
{
  local ctr
  declare -i ctr=0
  local QUANT=$1; local STATNM=$2; local RNM=$3
  local ORNM=$4; local MRNM=$5
  local STIME=$6; local IDNM=$7
  shift; shift; shift; shift; shift; shift; shift
  local TIMEOUT=$1; shift
  eval local LIST=( \"\${${ORNM}S[@]}\" )
  eval local MLIST=( \"\${${MRNM}S[@]}\" )
  if test "$RNM" != "NONE"; then echo -n "New $RNM: "; fi
  local RC=0
  local RESP
  # FIXME: Should we get a token once here and reuse it?
  for no in `seq 0 $(($QUANT-1))`; do
    local AZN=$(($no%$NOAZS))
    local AZ=$(($AZ+1))
    local VAL=${LIST[$ctr]}
    local MVAL=${MLIST[$ctr]}
    local CMD=`eval echo $@ 2>&1`
    local STM=$(date +%s)
    if test -n "$STIME"; then eval "${STIME}+=( $STM )"; fi
    let APICALLS+=1
    RESP=$(ostackcmd_id $IDNM $TIMEOUT $CMD)
    RC=$?
    #echo "DEBUG: ostackcmd_id $CMD => $RC" 1>&2
    updAPIerr $RC
    local TM
    read TM ID <<<"$RESP"
    eval ${STATNM}+="($TM)"
    let ctr+=1
    # Workaround for teuto.net
    if test "$1" = "cinder" && [[ $OS_AUTH_URL == *teutostack* ]]; then echo -en " ${RED}+5s${NORM} " 1>&2; sleep 5; fi
    if test $RC != 0; then echo -e "${YELLOW}ERROR: $RNM creation failed$NORM" 1>&2; return 1; fi
    if test -n "$ID" -a "$RNM" != "NONE"; then echo -n "$ID "; fi
    eval ${RNM}S+="($ID)"
  done
  if test "$RNM" != "NONE"; then echo; fi
}

# Delete a number of resources
# $1 => name of timing statistics array
# $2 => name of array containing resources ("S" appended)
# $3 => name of array to store timestamps (optional, use "" if unneeded)
# $4 => timeout
# $5- > openstack command to be called
# The UUID from the resource list ($2) is appended to the command.
#
# STATNM RSRCNM DTIME COMMAND
deleteResources()
{
  local STATNM=$1; local RNM=$2; local DTIME=$3
  local ERR=0
  shift; shift; shift
  local TIMEOUT=$1; shift
  local FAILDEL=()
  eval local LIST=( \"\${${ORNM}S[@]}\" )
  #eval local varAlias=( \"\${myvar${varname}[@]}\" )
  eval local LIST=( \"\${${RNM}S[@]}\" )
  #echo $LIST
  test -n "$LIST" && echo -n "Del $RNM: "
  #for rsrc in $LIST; do
  local LN=${#LIST[@]}
  local RESP
  while test ${#LIST[*]} -gt 0; do
    local rsrc=${LIST[-1]}
    echo -n "$rsrc "
    local DTM=$(date +%s)
    if test -n "$DTIME"; then eval "${DTIME}+=( $DTM )"; fi
    local TM
    let APICALLS+=1
    RESP=$(ostackcmd_id id $TIMEOUT $@ $rsrc)
    local RC="$?"
    updAPIerr $RC
    read TM ID <<<"$RESP"
    eval ${STATNM}+="($TM)"
    if test $RC != 0; then
      echo -e "${YELLOW}ERROR deleting $RNM $rsrc; retry and continue ...$NORM" 1>&2
      let ERR+=1
      sleep 2
      RESP=$(ostackcmd_id id $(($TIMEOUT+8)) $@ $rsrc)
      RC=$?
      updAPIerr $RC
      if test $RC != 0; then FAILDEL+=($rsrc); fi
    fi
    unset LIST[-1]
  done
  test $LN -gt 0 && echo
  # FIXME: Should we try again immediately?
  if test -n "$FAILDEL"; then
    echo "Store failed dels in REM${RNM}S for later re-cleanup: $FAILDEL"
    eval "REM${RNM}S=(${FAILDEL[*]})"
  fi
  return $ERR
}

# Convert status to colored one-char string
# $1 => status string
# $2 => wanted1
# $3 => wanted2 (optional)
# Return code: 2 == found, 1 == ERROR, 0 in progress
colstat()
{
  if test "$2" == "NONNULL" -a -n "$1" -a "$1" != "null"; then
	echo -e "${GREEN}*${NORM}"; return 2
  elif test "$2" == "$1" || test -n "$3" -a "$3" == "$1"; then
	echo -e "${GREEN}${1:0:1}${NORM}"; return 2
  elif test "${1:0:5}" == "error" -o "${1:0:5}" == "ERROR"; then
	echo -e "${RED}${1:0:1}${NORM}"; return 1
  elif test -n "$1"; then
	echo "${1:0:1}"
  else
	echo "?"
  fi
  return 0
}


# Wait for resources reaching a desired state
# $1 => name of timing statistics array
# $2 => name of array containing resources ("S" appended)
# $3 => name of array to collect completion timing stats
# $4 => name of array with start times
# $5 => value to wait for
# $6 => alternative value to wait for
# $7 => field name to monitor
# $8 => timeout
# $9- > openstack command for querying status
# The values from $2 get appended to the command
#
# STATNM RSRCNM CSTAT STIME PROG1 PROG2 FIELD COMMAND
waitResources()
{
  local STATNM=$1; local RNM=$2; local CSTAT=$3; local STIME=$4
  local COMP1=$5; local COMP2=$6; local IDNM=$7
  shift; shift; shift; shift; shift; shift; shift
  local TIMEOUT=$1; shift
  local STATI=()
  eval local RLIST=( \"\${${RNM}S[@]}\" )
  eval local SLIST=( \"\${${STIME}[@]}\" )
  local LAST=$(( ${#RLIST[@]} - 1 ))
  declare -i ctr=0
  declare -i WERR=0
  local RESP
  while test -n "${SLIST[*]}" -a $ctr -le 320; do
    local STATSTR=""
    for i in $(seq 0 $LAST ); do
      local rsrc=${RLIST[$i]}
      if test -z "${SLIST[$i]}"; then STATSTR+=$(colstat "${STATI[$i]}" "$COMP1" "$COMP2"); continue; fi
      local CMD=`eval echo $@ $rsrc 2>&1`
      let APICALLS+=1
      RESP=$(ostackcmd_id $IDNM $TIMEOUT $CMD)
      local RC=$?
      updAPIerr $RC
      local TM STAT
      read TM STAT <<<"$RESP"
      eval ${STATNM}+="( $TM )"
      if test $RC != 0; then echo -e "\n${YELLOW}ERROR: Querying $RNM $rsrc failed$NORM" 1>&2; return 1; fi
      STATI[$i]=$STAT
      STATSTR+=$(colstat "$STAT" "$COMP1" "$COMP2")
      STE=$?
      echo -en "Wait $RNM: $STATSTR\r"
      if test $STE != 0; then
	if test $STE = 1; then
          echo -e "\n${YELLOW}ERROR: $NM $rsrc status $STAT$NORM" 1>&2 #; return 1
          let WERR+=1
        fi
        TM=$(date +%s)
	TM=$(python -c "print \"%i\" % ($TM-${SLIST[$i]})")
	eval ${CSTAT}+="($TM)"
	if test -n "$GRAFANA"; then
	  # log time / rc to grafana
	  if test $STE -ge 2; then RC=0; else RC=$STE; fi
	  curl -si -XPOST 'http://localhost:8186/write?db=cicd' --data-binary "$GRAFANANM,cmd=wait$RNM,method=$COMP1 duration=$TM,return_code=$RC $(date +%s%N)" >/dev/null
	fi
	unset SLIST[$i]
      fi
    done
    echo -en "Wait $RNM: $STATSTR\r"
    if test -z "${SLIST[*]}"; then echo; return $WERR; fi
    let ctr+=1
    sleep 2
  done
  if test $ctr -ge 320; then let WERR+=1; fi
  echo
  return $WERR
}

# Wait for resources reaching a desired state
# $1 => name of timing statistics array
# $2 => name of array containing resources ("S" appended)
# $3 => name of array to collect completion timing stats
# $4 => name of array with start times
# $5 => value to wait for (special XDELX)
# $6 => alternative value to wait for 
#       (special: 2ndary XDELX results in waiting also for ERRORED res.)
# $7 => number of column (0 based)
# $8 => timeout
# $9- > openstack command for querying status
# The values from $2 get appended to the command
#
# STATNM RSRCNM CSTAT STIME PROG1 PROG2 FIELD COMMAND
waitlistResources()
{
  local STATNM=$1; local RNM=$2; local CSTAT=$3; local STIME=$4
  local COMP1=$5; local COMP2=$6; local COL=$7
  local NERR=0
  shift; shift; shift; shift; shift; shift; shift
  local TIMEOUT=$1; shift
  local STATI=()
  eval local RLIST=( \"\${${RNM}S[@]}\" )
  eval local SLIST=( \"\${${STIME}[@]}\" )
  local LAST=$(( ${#RLIST[@]} - 1 ))
  local PARSE="^|"
  for no in $(seq 1 $COL); do PARSE="$PARSE[^|]*|"; done
  PARSE="$PARSE *\([^|]*\)|.*\$"
  #echo "$PARSE"
  declare -i ctr=0
  declare -i WERR=0
  while test -n "${SLIST[*]}" -a $ctr -le 240; do
    local STATSTR=""
    local CMD=`eval echo $@ 2>&1`
    ostackcmd_tm $STATNM $TIMEOUT $CMD
    if test $? != 0; then
      echo -e "\n${YELLOW}ERROR: $CMD => $OSTACKRESP$NORM" 1>&2
      # Only bail out after 4th error;
      # so we retry in case there are spurious 500/503 (throttling) errors
      # Do not give up so early on waiting for deletion ...
      let NERR+=1
      if test $NERR -ge 4 -a "$COMP1" != "XDELX" -o $NERR -ge 20; then return 1; fi
      sleep 10
    fi
    local TM
    for i in $(seq 0 $LAST ); do
      local rsrc=${RLIST[$i]}
      if test -z "${SLIST[$i]}"; then STATSTR+=$(colstat "${STATI[$i]}" "$COMP1" "$COMP2"); continue; fi
      local STAT=$(echo "$OSTACKRESP" | grep "^| $rsrc" | sed -e "s@$PARSE@\1@" -e 's/ *$//')
      #echo "STATUS: \"$STAT\""
      if test "$COMP1" == "XDELX" -a -z "$STAT"; then STAT="XDELX"; fi
      STATI[$i]="$STAT"
      STATSTR+=$(colstat "$STAT" "$COMP1" "$COMP2")
      STE=$?
      #echo -en "Wait $RNM: $STATSTR\r"
      # Found or ERROR
      if test $STE != 0; then
        # ERROR
        if test $STE == 1; then
          # Really wait for deletion of errored resources?
          if test "$COMP2" == "XDELX"; then continue; fi
          let WERR+=1
          echo -e "${YELLOW}ERROR: $NM $rsrc status $STAT$NORM" 1>&2 #; return 1
        fi
        # Found
        TM=$(date +%s)
        TM=$(python -c "print \"%i\" % ($TM-${SLIST[$i]})")
        unset SLIST[$i]
        eval ${CSTAT}+="($TM)"
        if test -n "$GRAFANA"; then
          # log time / rc to grafana
          if test $STE -ge 2; then RC=0; else RC=$STE; fi
          curl -si -XPOST 'http://localhost:8186/write?db=cicd' --data-binary "$GRAFANANM,cmd=wait$RNM,method=$COMP1 duration=$TM,return_code=$RC $(date +%s%N)" >/dev/null
        fi
      fi
    done
    echo -en "Wait $RNM[${#SLIST[*]}/${#RLIST[*]}]: $STATSTR \r"
    if test -z "${SLIST[*]}"; then echo; return $WERR; fi
    sleep 3
    let ctr+=1
  done
  if test $ctr -ge 320; then let WERR+=1; fi
  if test -n "${SLIST[*]}"; then echo -e "\nLEFT: ${RED}${SLIST[*]}${NORM}"; else echo; fi
  return $WERR
}

# UNUSED!
# Wait for deletion of resources
# $1 => name of timing statistics array
# $2 => name of array containing resources ("S" appended)
# $3 => name of array to collect completion timing stats
# $4 => name of array with deletion start times
# $5 => timeout
# $6- > openstack command for querying status
# The values from $2 get appended to the command
#
# STATNM RSRCNM DSTAT DTIME COMMAND
waitdelResources()
{
  local STATNM=$1; local RNM=$2; local DSTAT=$3; local DTIME=$4
  shift; shift; shift; shift
  local TIMEOUT=$1; shift
  eval local RLIST=( \"\${${RNM}S[@]}\" )
  eval local DLIST=( \"\${${DTIME}[@]}\" )
  local STATI=()
  local LAST=$(( ${#RLIST[@]} - 1 ))
  local STATI=()
  local RESP
  #echo "waitdelResources $STATNM $RNM $DSTAT $DTIME - ${RLIST[*]} - ${DLIST[*]}"
  declare -i ctr=0
  while test -n "${DLIST[*]}"i -a $ctr -le 320; do
    local STATSTR=""
    for i in $(seq 0 $LAST); do
      local rsrc=${RLIST[$i]}
      if test -z "${DLIST[$i]}"; then STATSTR+=$(colstat "${STATI[$i]}" "XDELX" ""); continue; fi
      local CMD=`eval echo $@ $rsrc`
      let APICALLS+=1
      RESP=$(ostackcmd_id DELETE $TIMEOUT $CMD)
      local RC=$?
      updAPIerr $RC
      local TM STAT
      read TM STAT <<<"$RESP"
      eval ${STATNM}+="( $TM )"
      if test $RC != 0; then
        TM=$(date +%s)
	TM=$(python -c "print \"%i\" % ($TM-${DLIST[$i]})")
	eval ${DSTAT}+="($TM)"
	unset DLIST[$i]
        STAT="XDELX"
      fi
      STATI[$i]=$STAT
      STARTSTR+=$(colstat "$STAT" "XDELX" "")
      if test -n "$GRAFANA"; then
	# log time / rc to grafana
        rc2grafana $RC
	curl -si -XPOST 'http://localhost:8186/write?db=cicd' --data-binary "$GRAFANANM,cmd=wait$RNM,method=DEL duration=$TM,return_code=$GRC $(date +%s%N)" >/dev/null
      fi
      #echo -en "WaitDel $RNM: $STATSTR\r"
    done
    echo -en "WaitDel $RNM: $STATSTR \r"
    if test -z "${DLIST[*]}"; then echo; return 0; fi
    sleep 2
    let ctr+=1
  done
  if test $ctr -ge 320; then let WERR+=1; fi
  if test -n "${DLIST[*]}"; then echo -e "\nLEFT: ${RED}${DLIST[*]}${NORM}"; else echo; fi
  return $WERR
}

# STATNM RESRNM COMMAND
# Only for the log file
# $1 => STATS
# $2 => Resource listname
# $3 => timeout
showResources()
{
  local STATNM=$1
  local RNM=$2
  local RESP
  shift; shift
  local TIMEOUT=$1; shift
  eval local LIST=( \"\${$RNM}S[@]\" )
  local rsrc TM
  while rsrc in ${LIST}; do
    let APICALLS+=1
    RESP=$(ostackcmd_id id $TIMEOUT $@ $rsrc)
    updAPIerr $?
    #read TM ID <<<"$RESP"
  done
}


# The commands that create and delete resources ...

createRouters()
{
  createResources 1 NETSTATS ROUTER NONE NONE "" id $FIPTIMEOUT neutron router-create ${RPRE}Router
}

deleteRouters()
{
  deleteResources NETSTATS ROUTER "" $(($FIPTIMEOUT+8)) neutron router-delete
}

createNets()
{
  createResources 1 NETSTATS JHNET NONE NONE "" id $NETTIMEOUT neutron net-create "${RPRE}NET_JH\$no"
  createResources $NONETS NETSTATS NET NONE NONE "" id $NETTIMEOUT neutron net-create "${RPRE}NET_\$no"
}

deleteNets()
{
  deleteResources NETSTATS NET "" 12 neutron net-delete
  deleteResources NETSTATS JHNET "" 12 neutron net-delete
}

JHSUBNETIP=10.250.250.0/24

createSubNets()
{
  if test -n "$NAMESERVER"; then
    createResources 1 NETSTATS JHSUBNET JHNET NONE "" id $NETTIMEOUT neutron subnet-create --dns-nameserver 9.9.9.9 --dns-nameserver $NAMESERVER --name "${RPRE}SUBNET_JH\$no" "\$VAL" "$JHSUBNETIP"
    createResources $NONETS NETSTATS SUBNET NET NONE "" id $NETTIMEOUT neutron subnet-create --dns-nameserver $NAMESERVER --dns-nameserver 9.9.9.9 --name "${RPRE}SUBNET_\$no" "\$VAL" "10.250.\$no.0/24"
  else
    createResources 1 NETSTATS JHSUBNET JHNET NONE "" id $NETTIMEOUT neutron subnet-create --name "${RPRE}SUBNET_JH\$no" "\$VAL" "$JHSUBNETIP"
    createResources $NONETS NETSTATS SUBNET NET NONE "" id $NETTIMEOUT neutron subnet-create --name "${RPRE}SUBNET_\$no" "\$VAL" "10.250.\$no.0/24"
  fi
}

deleteSubNets()
{
  deleteResources NETSTATS SUBNET "" $NETTIMEOUT neutron subnet-delete
  deleteResources NETSTATS JHSUBNET "" $NETTIMEOUT neutron subnet-delete
}

# Plug subnets into router
createRIfaces()
{
  createResources 1 NETSTATS NONE JHSUBNET NONE "" id $FIPTIMEOUT neutron router-interface-add ${ROUTERS[0]} "\$VAL"
  createResources $NONETS NETSTATS NONE SUBNET NONE "" id $FIPTIMEOUT neutron router-interface-add ${ROUTERS[0]} "\$VAL"
}

# Remove subnet interfaces on router
deleteRIfaces()
{
  if test -z "${ROUTERS[0]}"; then return 0; fi
  deleteResources NETSTATS SUBNET "" $FIPTIMEOUT neutron router-interface-delete ${ROUTERS[0]}
  deleteResources NETSTATS JHSUBNET "" $FIPTIMEOUT neutron router-interface-delete ${ROUTERS[0]}
}

# Setup security groups with their rulesets
createSGroups()
{
  local RESP
  NAMES=( ${RPRE}SG_JumpHost ${RPRE}SG_Internal )
  createResources 2 NETSTATS SGROUP NAME NONE "" id $NETTIMEOUT neutron security-group-create "\$VAL" || return
  # And set rules ... (we don't need to keep track of and delete them)
  SG0=${SGROUPS[0]}
  SG1=${SGROUPS[1]}
  # Configure SGs: We can NOT allow any references to SG0, as the allowed-address-pair setting renders SGs useless
  #  that reference the SG0
  let APICALLS+=10
  #RESP=$(ostackcmd_id id neutron security-group-rule-create --direction ingress --ethertype IPv4 --remote-group-id $SG0 $SG0)
  RESP=$(ostackcmd_id id $NETTIMEOUT neutron security-group-rule-create --direction ingress --ethertype IPv4 --remote-ip-prefix $JHSUBNETIP $SG0)
  updAPIerr $?
  read TM ID <<<"$RESP"
  NETSTATS+=( $TM )
  #RESP=$(ostackcmd_id id $NETTIMEOUT neutron security-group-rule-create --direction ingress --ethertype IPv6 --remote-group-id $SG0 $SG0)
  #updAPIerr $?
  #read TM ID <<<"$RESP"
  #NETSTATS+=( $TM )
  # Configure SGs: Internal ingress allowed
  RESP=$(ostackcmd_id id $NETTIMEOUT neutron security-group-rule-create --direction ingress --ethertype IPv4 --remote-group-id $SG1 $SG1)
  updAPIerr $?
  read TM ID <<<"$RESP"
  NETSTATS+=( $TM )
  RESP=$(ostackcmd_id id $NETTIMEOUT neutron security-group-rule-create --direction ingress --ethertype IPv6 --remote-group-id $SG1 $SG1)
  updAPIerr $?
  read TM ID <<<"$RESP"
  NETSTATS+=( $TM )
  # Configure RPRE_SG_JumpHost rule: All from the other group, port 22 and 222- from outside
  RESP=$(ostackcmd_id id $NETTIMEOUT neutron security-group-rule-create --direction ingress --ethertype IPv4 --remote-group-id $SG1 $SG0)
  updAPIerr $?
  read TM ID <<<"$RESP"
  NETSTATS+=( $TM )
  RESP=$(ostackcmd_id id $NETTIMEOUT neutron security-group-rule-create --direction ingress --ethertype IPv4 --protocol tcp --port-range-min 22 --port-range-max 22 --remote-ip-prefix 0/0 $SG0)
  updAPIerr $?
  read TM ID <<<"$RESP"
  NETSTATS+=( $TM )
  RESP=$(ostackcmd_id id $NETTIMEOUT neutron security-group-rule-create --direction ingress --ethertype IPv4 --protocol tcp --port-range-min 222 --port-range-max $((222+($NOVMS-1)/$NOAZS)) --remote-ip-prefix 0/0 $SG0)
  updAPIerr $?
  read TM ID <<<"$RESP"
  NETSTATS+=( $TM )
  RESP=$(ostackcmd_id id $NETTIMEOUT neutron security-group-rule-create --direction ingress --ethertype IPv4 --protocol icmp --port-range-min 8 --port-range-max 0 --remote-ip-prefix 0/0 $SG0)
  updAPIerr $?
  read TM ID <<<"$RESP"
  NETSTATS+=( $TM )
  # Configure RPRE_SG_Internal rule: ssh and https and ping from the other group
  #RESP=$(ostackcmd_id id $NETTIMEOUT neutron security-group-rule-create --direction ingress --ethertype IPv4 --protocol tcp --port-range-min 22 --port-range-max 22 --remote-group-id $SG0 $SG1)
  RESP=$(ostackcmd_id id $NETTIMEOUT neutron security-group-rule-create --direction ingress --ethertype IPv4 --protocol tcp --port-range-min 22 --port-range-max 22 --remote-ip-prefix $JHSUBNETIP $SG1)
  updAPIerr $?
  read TM ID <<<"$RESP"
  NETSTATS+=( $TM )
  #RESP=$(ostackcmd_id id $NETTIMEOUT neutron security-group-rule-create --direction ingress --ethertype IPv4 --protocol tcp --port-range-min 443 --port-range-max 443 --remote-group-id $SG0 $SG1)
  #RESP=$(ostackcmd_id id $NETTIMEOUT neutron security-group-rule-create --direction ingress --ethertype IPv4 --protocol tcp --port-range-min 443 --port-range-max 443 --remote-ip-prefix $JHSUBNETIP $SG1)
  #updAPIerr $?
  #read TM ID <<<"$RESP"
  #NETSTATS+=( $TM )
  #RESP=$(ostackcmd_id id $NETTIMEOUT neutron security-group-rule-create --direction ingress --ethertype IPv4 --protocol icmp --port-range-min 8 --port-range-max 0 --remote-group-id $SG0 $SG1)
  RESP=$(ostackcmd_id id $NETTIMEOUT neutron security-group-rule-create --direction ingress --ethertype IPv4 --protocol icmp --port-range-min 8 --port-range-max 0 --remote-ip-prefix $JHSUBNETIP $SG1)
  updAPIerr $?
  read TM ID <<<"$RESP"
  NETSTATS+=( $TM )
  #neutron security-group-show $SG0
  #neutron security-group-show $SG1
}

cleanupPorts()
{
  RPORTS=( $(findres ${RPRE}Port_ neutron port-list) )
  deleteResources NETSTATS RPORT "" $NETTIMEOUT neutron port-delete
  #RVIPS=( $(findres ${RPRE}VirtualIP neutron port-list) )
  #deleteResources NETSTATS RVIP "" $NETTIMEOUT neutron port-delete
}


deleteSGroups()
{
  #neutron port-list
  #neutron security-group-list
  deleteResources NETSTATS SGROUP "" $NETTIMEOUT neutron security-group-delete
}

createVIPs()
{
  createResources 1 NETSTATS VIP NONE NONE "" id $NETTIMEOUT neutron port-create --name ${RPRE}VirtualIP --security-group ${SGROUPS[0]} ${JHNETS[0]}
  # FIXME: We should not need --allowed-adress-pairs here ...
}

deleteVIPs()
{
  deleteResources NETSTATS VIP "" $NETTIMEOUT neutron port-delete
}

createJHPorts()
{
  local RESP RC TM ID
  createResources $NOAZS NETSTATS JHPORT NONE NONE "" id $NETTIMEOUT neutron port-create --name "${RPRE}Port_JH\${no}" --security-group ${SGROUPS[0]} ${JHNETS[0]} || return
  for i in `seq 0 $((NOAZS-1))`; do
    let APICALLS+=1
    RESP=$(ostackcmd_id id $NETTIMEOUT neutron port-update ${JHPORTS[$i]} --allowed-address-pairs type=dict list=true ip_address=0.0.0.0/1 ip_address=128.0.0.0/1)
    RC=$?
    updAPIerr $RC
    read TM ID <<<"$RESP"
    NETSTATS+=( $TM )
    if test $RC != 0; then echo -e "${YELLOW}ERROR: Failed setting allowed-adr-pair for port ${JHPORTS[$i]}$NORM" 1>&2; return 1; fi
  done
}

createPorts()
{
  if test -n "$MANUALPORTSETUP"; then
    createResources $NOVMS NETSTATS PORT NONE NONE "" id $NETTIMEOUT neutron port-create --name "${RPRE}Port_VM\${no}" --security-group ${SGROUPS[1]} "\${NETS[\$((\$no%$NONETS))]}"
  fi
}

deleteJHPorts()
{
  deleteResources NETSTATS JHPORT "" $NETTIMEOUT neutron port-delete
}

deletePorts()
{
  deleteResources NETSTATS PORT "" $NETTIMEOUT neutron port-delete
}

createJHVols()
{
  JVOLSTIME=()
  createResources $NOAZS VOLSTATS JHVOLUME NONE NONE JVOLSTIME id $CINDERTIMEOUT cinder create --image-id $JHIMGID --name ${RPRE}RootVol_JH\$no --availability-zone \${AZS[\$AZN]} $JHVOLSIZE
}

# STATNM RSRCNM CSTAT STIME PROG1 PROG2 FIELD COMMAND
waitJHVols()
{
  #waitResources VOLSTATS JHVOLUME VOLCSTATS JVOLSTIME "available" "NA" "status" cinder show
  waitlistResources VOLSTATS JHVOLUME VOLCSTATS JVOLSTIME "available" "NA" 1 $CINDERTIMEOUT cinder list
}

deleteJHVols()
{
  deleteResources VOLSTATS JHVOLUME "" $CINDERTIMEOUT cinder delete
}

createVols()
{
  if test -n "$BOOTFROMIMAGE"; then return 0; fi
  VOLSTIME=()
  createResources $NOVMS VOLSTATS VOLUME NONE NONE VOLSTIME id $CINDERTIMEOUT cinder create --image-id $IMGID --name ${RPRE}RootVol_VM\$no --availability-zone \${AZS[\$AZN]} $VOLSIZE
}

# STATNM RSRCNM CSTAT STIME PROG1 PROG2 FIELD COMMAND
waitVols()
{
  if test -n "$BOOTFROMIMAGE"; then return 0; fi
  #waitResources VOLSTATS VOLUME VOLCSTATS VOLSTIME "available" "NA" "status" cinder show
  waitlistResources VOLSTATS VOLUME VOLCSTATS VOLSTIME "available" "NA" 1 $CINDERTIMEOUT cinder list
}

deleteVols()
{
  if test -n "$BOOTFROMIMAGE"; then return 0; fi
  deleteResources VOLSTATS VOLUME "" $CINDERTIMEOUT cinder delete
}

createKeypairs()
{
  UMASK=$(umask)
  umask 0077
  ostackcmd_tm NOVASTATS $NOVATIMEOUT nova keypair-add ${RPRE}Keypair_JH || return 1
  echo "$OSTACKRESP" > ${RPRE}Keypair_JH.pem
  KEYPAIRS+=( "${RPRE}Keypair_JH" )
  ostackcmd_tm NOVASTATS $NOVATIMEOUT nova keypair-add ${RPRE}Keypair_VM || return 1
  echo "$OSTACKRESP" > ${RPRE}Keypair_VM.pem
  KEYPAIRS+=( "${RPRE}Keypair_VM" )
  umask $UMASK
}

deleteKeypairs()
{
  deleteResources NOVASTATS KEYPAIR "" $NOVATIMEOUT nova keypair-delete
  #rm ${RPRE}Keypair_VM.pem
  #rm ${RPRE}Keypair_JH.pem
}

# Extract IP address from neutron port-show output
extract_ip()
{
  echo "$1" | grep '| fixed_ips ' | sed 's/^.*"ip_address": "\([0-9a-f:.]*\)".*$/\1/'
}

# Create Floating IPs, and set route via Virtual IP
SNATROUTE=""
createFIPs()
{
  local VIP FLOAT RESP
  #createResources $NOAZS NETSTATS JHPORT NONE NONE "" id $NETTIMEOUT neutron port-create --name "${RPRE}Port_JH\${no}" --security-group ${SGROUPS[0]} ${JHNETS[0]} || return
  ostackcmd_tm NETSTATS $NETTIMEOUT neutron net-external-list || return 1
  EXTNET=$(echo "$OSTACKRESP" | grep '^| [0-9a-f-]* |' | sed 's/^| [0-9a-f-]* | \([^ ]*\).*$/\1/')
  # Not needed on OTC, but for most other OpenStack clouds:
  # Connect Router to external network gateway
  ostackcmd_tm NETSTATS $NETTIMEOUT neutron router-gateway-set ${ROUTERS[0]} $EXTNET
  # Actually this fails if the port is not assigned to a VM yet
  #  -- we can not associate a FIP to a port w/o dev owner
  # So wait for JHPORTS having a device owner
  #echo "Wait for JHPorts: "
  waitResources NETSTATS JHPORT JPORTSTAT JVMSTIME "NONNULL" "NONONO" "device_owner" $NETTIMEOUT neutron port-show
  # Now FIP creation is safe
  createResources $NOAZS FIPSTATS FIP JHPORT NONE "" id $FIPTIMEOUT neutron floatingip-create --port-id \$VAL $EXTNET
  if test $? != 0; then return 1; fi
  # Use API to tell VPC that the VIP is the next hop (route table)
  ostackcmd_tm NETSTATS $NETTIMEOUT neutron port-show ${VIPS[0]} || return 1
  VIP=$(extract_ip "$OSTACKRESP")
  # Find out whether the router does SNAT ...
  RESP=$(ostackcmd_id external_gateway_info $NETTIMEOUT neutron router-show ${ROUTERS[0]})
  updAPIerr $?
  read TM EXTGW <<<"$RESP"
  NETSTATS+=( $TM )
  SNAT=$(echo $EXTGW | sed 's/^[^,]*, "enable_snat": \([^ }]*\).*$/\1/')
  if test "$SNAT" = "false"; then
    ostackcmd_tm NETSTATS $NETTIMEOUT neutron router-update ${ROUTERS[0]} --routes type=dict list=true destination=0.0.0.0/0,nexthop=$VIP
  fi
  if test $? != 0; then
    echo -e "$BOLD We lack the ability to set VPC route via SNAT gateways by API, will be fixed soon"
    echo -e " Please set next hop $VIP to VPC ${RPRE}Router (${ROUTERS[0]}) routes $NORM"
    SNATROUTE=""
  else
    #SNATROUTE=$(echo "$OSTACKRESP" | grep "^| *id *|" | sed -e "s/^| *id *| *\([^|]*\).*\$/\1/" -e 's/ *$//')
    echo "SNATROUTE: destination=0.0.0.0/0,nexthop=$VIP"
    SNATROUTE=1
  fi
  FLOAT=""
  ostackcmd_tm NETSTATS $NETTIMEOUT neutron floatingip-list || return 1
  for PORT in ${FIPS[*]}; do
    FLOAT+=" $(echo "$OSTACKRESP" | grep $PORT | sed 's/^|[^|]*|[^|]*| \([0-9:.]*\).*$/\1/')"
  done
  echo "Floating IPs: $FLOAT"
  FLOATS=( $FLOAT )
}

# Delete VIP nexthop and EIPs
deleteFIPs()
{
  if test -n "$SNATROUTE" -a -n "${ROUTERS[0]}"; then
    ostackcmd_tm NETSTATS $NETTIMEOUT neutron router-update ${ROUTERS[0]} --no-routes
  fi
  OLDFIPS=(${FIPS[*]})
  deleteResources FIPSTATS FIP "" $FIPTIMEOUT neutron floatingip-delete
}

# Create a list of port forwarding rules (redirection/fwdmasq)
declare -a REDIRS
calcRedirs()
{
  local port ptn pi IP STR off
  REDIRS=()
  if test ${#PORTS[*]} -gt 0; then
    declare -i ptn=222
    declare -i pi=0
    for port in ${PORTS[*]}; do
      ostackcmd_tm NETSTATS $NETTIMEOUT neutron port-show $port
      IP=$(extract_ip "$OSTACKRESP")
      STR="0/0,$IP,tcp,$ptn,22"
      off=$(($pi%$NOAZS))
      REDIRS[$off]="${REDIRS[$off]}$STR
"
      if test $(($off+1)) == $NOAZS; then let ptn+=1; fi
      let pi+=1
    done
    #for off in $(seq 0 $(($NOAZS-1))); do
    #  echo " REDIR $off: ${REDIRS[$off]}"
    #done
  fi
}

# JumpHosts creation with SNAT and port forwarding
createJHVMs()
{
  local VIP IP STR odd ptn RD USERDATA JHNUM port
  REDIRS=()
  ostackcmd_tm NETSTATS $NETTIMEOUT neutron port-show ${VIPS[0]} || return 1
  VIP=$(extract_ip "$OSTACKRESP")
  calcRedirs
  #echo "$VIP ${REDIRS[*]}"
  for JHNUM in $(seq 0 $(($NOAZS-1))); do
    if test -z "${REDIRS[$JHNUM]}"; then
      # No fwdmasq config possible yet
      USERDATA="#cloud-config
otc:
   internalnet:
      - 10.250/16
   snat:
      masqnet:
         - INTERNALNET
   addip:
      eth0: $VIP
"
    else
      RD=$(echo -n "${REDIRS[$JHNUM]}" |  sed 's@^0@         - 0@')
      USERDATA="#cloud-config
otc:
   internalnet:
      - 10.250/16
   snat:
      masqnet:
         - INTERNALNET
      fwdmasq:
$RD
   addip:
      eth0: $VIP
"
    fi
    echo "$USERDATA" > user_data.yaml
    cat user_data.yaml >> $LOGFILE
    createResources 1 NOVABSTATS JHVM JHPORT JHVOLUME JVMSTIME id $NOVABOOTTIMEOUT nova boot --flavor $JHFLAVOR --boot-volume ${JHVOLUMES[$JHNUM]} --key-name ${KEYPAIRS[0]} --user-data user_data.yaml --availability-zone ${AZS[$(($JHNUM%$NOAZS))]} --security-groups ${SGROUPS[0]} --nic port-id=${JHPORTS[$JHNUM]} ${RPRE}VM_JH$JHNUM || return
  done
}

# Fill PORTS array by matching part's device_ids with the VM UUIDs
collectPorts()
{
  local vm vmid
  ostackcmd_tm NETSTATS $NETTIMEOUT neutron port-list -c id -c device_id -c fixed_ips -f json
  for vm in $(seq 0 $(($NOVMS-1))); do
    vmid=${VMS[$vm]}
    if test -z "$vmid"; then sendalarm 1 "nova list" "VM $vm not found" $NOVATIMEOUT; continue; fi
    port=$(echo "$OSTACKRESP" | jq ".[] | select(.device_id == \"$vmid\") | .id" | tr -d '"')
    PORTS[$vm]=$port
  done
  echo "VM Ports: ${PORTS[*]}"
}

# When NOT creating ports before JHVM starts, we cannot pass the port fwd information
# via user-data as we don't know the IP addresses. So modify VM via ssh.
setPortForward()
{
  if test -n "$MANUALPORTSETUP"; then return; fi
  local JHNUM FWDMASQ SHEBANG SCRIPT
  # If we need to collect port info, do so now
  if test -z "${PORTS[*]}"; then collectPorts; fi 
  calcRedirs
  #echo "$VIP ${REDIRS[*]}"
  for JHNUM in $(seq 0 $(($NOAZS-1))); do
    if test -z "${REDIRS[$JHNUM]}"; then
      echo -e "${YELLOW}ERROR: No redirections?$NORM" 1>&2
      return 1
    fi
    FWDMASQ=$( echo ${REDIRS[$JHNUM]} )
    ssh-keygen -R ${FLOATS[$JHNUM]} -f ~/.ssh/known_hosts >/dev/null 2>&1
    SHEBANG='#!'
    SCRIPT=$(echo "$SHEBANG/bin/bash
sed -i 's@^FW_FORWARD_MASQ=.*\$@FW_FORWARD_MASQ=\"$FWDMASQ\"@' /etc/sysconfig/SuSEfirewall2
systemctl restart SuSEfirewall2
")
    echo "$SCRIPT" | ssh -i ${KEYPAIRS[0]}.pem -o "StrictHostKeyChecking=no" linux@${FLOATS[$JHNUM]} "cat - >upd_sfw2"
    ssh -i ${KEYPAIRS[0]}.pem -o "StrictHostKeyChecking=no" linux@${FLOATS[$JHNUM]} sudo "/bin/bash ./upd_sfw2"
  done
}

waitJHVMs()
{
  #waitResources NOVASTATS JHVM VMCSTATS JVMSTIME "ACTIVE" "NA" "status" nova show
  waitlistResources NOVASTATS JHVM VMCSTATS JVMSTIME "ACTIVE" "NONONO" 2 $NOVATIMEOUT nova list
}
deleteJHVMs()
{
  JVMSTIME=()
  deleteResources NOVABSTATS JHVM JVMSTIME $NOVATIMEOUT nova delete
}

waitdelJHVMs()
{
  #waitdelResources NOVASTATS JHVM VMDSTATS JVMSTIME nova show
  waitlistResources NOVASTATS JHVM VMDSTATS JVMSTIME "XDELX" "$FORCEDEL" 2 $NOVATIMEOUT nova list
}

# Create many VMs with one API call (option -D)
createVMsAll()
{
  local netno AZ THISNOVM vmid off STMS
  local ERRS=0
  local UDTMP=./user_data_VM.$$.yaml
  echo -e "#cloud-config\nwrite_files:\n - content: |\n      # TEST FILE CONTENTS\n      api_monitor.sh.$$.ALL\n   path: /tmp/testfile\n   permissions: '0644'" > $UDTMP
  declare -a STMS
  echo -n "Create VMs in batches: "
  for netno in $(seq 0 $(($NONETS-1))); do
    AZ=${AZS[$(($netno%$NOAZS))]}
    THISNOVM=$((($NOVMS+$NONETS-$netno-1)/$NONETS))
    STMS[$netno]=$(date +%s)
    ostackcmd_tm NOVABSTATS $(($NOVABOOTTIMEOUT+$THISNOVM*$DEFTIMEOUT/2)) nova boot --flavor $FLAVOR --image $IMGID --key-name ${KEYPAIRS[1]} --availability-zone $AZ --security-groups ${SGROUPS[1]} --nic net-id=${NETS[$netno]} --user-data $UDTMP ${RPRE}VM_VM_NET$netno --min-count=$THISNOVM --max-count=$THISNOVM
    let ERRS+=$?
    # TODO: More error handling here?
  done
  sleep 1
  # Collect VMIDs
  ostackcmd_tm NOVASTATS $NOVATIMEOUT nova list
  for netno in $(seq 0 $(($NONETS-1))); do
    declare -i off=$netno
    OLDIFS="$IFS"; IFS="|"
    #nova list | grep ${RPRE}VM_VM_NET$netno
    while read sep vmid sep; do
      #echo -n " VM$off=$vmid"
      IFS=" " VMS[$off]=$(echo $vmid)
      IFS=" " VMSTIME[$off]=${STMS[$netno]}
      let off+=$NONETS
    done  < <(echo "$OSTACKRESP" | grep "${RPRE}VM_VM_NET$netno")
    IFS="$OLDIFS"
    #echo
  done
  echo "${VMS[*]}"
  #collectPorts
  return $ERRS
}

# Classic creation of all VMs, one by one
createVMs()
{
  if test -n "$BOOTALLATONCE"; then createVMsAll; return; fi
  local UDTMP=./user_data_VM.$$.yaml
  for no in $(seq 0 $NOVMS); do
    echo -e "#cloud-config\nwrite_files:\n - content: |\n      # TEST FILE CONTENTS\n      api_monitor.sh.$$.$no\n   path: /tmp/testfile\n   permissions: '0644'" > $UDTMP.$no
  done
  if test -n "$BOOTFROMIMAGE"; then
    if test -n "$MANUALPORTSETUP"; then
      createResources $NOVMS NOVABSTATS VM PORT VOLUME VMSTIME id $NOVABOOTTIMEOUT nova boot --flavor $FLAVOR --image $IMGID --key-name ${KEYPAIRS[1]} --availability-zone \${AZS[\$AZN]} --nic port-id=\$VAL --user-data $UDTMP.\$no ${RPRE}VM_VM\$no
    else
      # SAVE: createResources $NOVMS NETSTATS PORT NONE NONE "" id neutron port-create --name "${RPRE}Port_VM\${no}" --security-group ${SGROUPS[1]} "\${NETS[\$((\$no%$NONETS))]}"
      createResources $NOVMS NOVABSTATS VM NET VOLUME VMSTIME id $NOVABOOTTIMEOUT nova boot --flavor $FLAVOR --image $IMGID --key-name ${KEYPAIRS[1]} --availability-zone \${AZS[\$AZN]} --security-groups ${SGROUPS[1]} --nic "net-id=\${NETS[\$((\$no%$NONETS))]}" --user-data $UDTMP.\$no ${RPRE}VM_VM\$no
    fi
  else
    if test -n "$MANUALPORTSETUP"; then
      createResources $NOVMS NOVABSTATS VM PORT VOLUME VMSTIME id $NOVABOOTTIMEOUT nova boot --flavor $FLAVOR --boot-volume \$MVAL --key-name ${KEYPAIRS[1]} --availability-zone \${AZS[\$AZN]} --nic port-id=\$VAL --user-data $UDTMP.\$no ${RPRE}VM_VM\$no
    else
      # SAVE: createResources $NOVMS NETSTATS PORT NONE NONE "" id neutron port-create --name "${RPRE}Port_VM\${no}" --security-group ${SGROUPS[1]} "\${NETS[\$((\$no%$NONETS))]}"
      createResources $NOVMS NOVABSTATS VM NET VOLUME VMSTIME id $NOVABOOTTIMEOUT nova boot --flavor $FLAVOR --boot-volume \$MVAL --key-name ${KEYPAIRS[1]} --availability-zone \${AZS[\$AZN]} --security-groups ${SGROUPS[1]} --nic "net-id=\${NETS[\$((\$no%$NONETS))]}" --user-data $UDTMP.\$no ${RPRE}VM_VM\$no
    fi
  fi
  local RC=$?
  rm $UDTMP.*
  return $RC
}

# Wait for VMs to get into active state
waitVMs()
{
  #waitResources NOVASTATS VM VMCSTATS VMSTIME "ACTIVE" "NA" "status" nova show
  waitlistResources NOVASTATS VM VMCSTATS VMSTIME "ACTIVE" "NONONO" 2 $NOVATIMEOUT nova list
}

# Remove VMs (one by one or by batch if we created in batches)
deleteVMs()
{
  VMSTIME=()
  if test -z "${VMS[*]}"; then return; fi
  if test -n "$BOOTALLATONCE"; then
    local DT vm
    echo "Del VM in batch: ${VMS[*]}"
    DT=$(date +%s)
    ostackcmd_tm NOVABSTATS $(($NOVMS*$DEFTIMEOUT/2+$NOVABOOTTIMEOUT)) nova delete ${VMS[*]}
    for vm in $(seq 0 $((${#VMS[*]}-1))); do VMSTIME[$vm]=$DT; done
  else
    deleteResources NOVABSTATS VM VMSTIME $NOVABOOTTIMEOUT nova delete
  fi
}

# Wait for VMs to disappear
waitdelVMs()
{
  #waitdelResources NOVASTATS VM VMDSTATS VMSTIME nova show
  waitlistResources NOVASTATS VM VMDSTATS VMSTIME XDELX $FORCEDEL 2 $NOVATIMEOUT nova list
}

# Meta data setting for test purposes
setmetaVMs()
{
  for no in `seq 0 $(($NOVMS-1))`; do
    ostackcmd_tm NOVASTATS $NOVATIMEOUT nova meta ${VMS[$no]} set deployment=cf server=$no || return 1
  done
}

# Wait for VMs being accessible behind fwdmasq (ports 222+)
wait222()
{
  local NCPROXY pno ctr JHNO waiterr red
  declare -i waiterr=0
  #if test -n "$http_proxy"; then NCPROXY="-X connect -x $http_proxy"; fi
  MAXWAIT=90
  for JHNO in $(seq 0 $(($NOAZS-1))); do
    echo -n "${FLOATS[$JHNO]} "
    echo -n "ping "
    declare -i ctr=0
    # First test JH
    while test $ctr -le $MAXWAIT; do
      ping -c1 -w2 ${FLOATS[$JHNO]} >/dev/null 2>&1 && break
      sleep 2
      echo -n "."
      let ctr+=1
    done
    if test $ctr -ge $MAXWAIT; then echo -e "${RED}JumpHost$JHNO (${FLOATS[$JHNO]}) not pingable${NORM}"; let waiterr+=1; fi
    # Now ssh
    echo -n " ssh "
    declare -i ctr=0
    while [ $ctr -le $MAXWAIT ]; do
      echo "quit" | nc $NCPROXY -w 2 ${FLOATS[$JHNO]} 22 >/dev/null 2>&1 && break
      echo -n "."
      sleep 2
      let ctr+=1
    done
    if [ $ctr -ge $MAXWAIT ]; then echo -ne " $RED timeout $NORM"; let waiterr+=1; fi
    # Now test VMs behind JH
    for red in ${REDIRS[$JHNO]}; do
      pno=${red#*tcp,}
      pno=${pno%%,*}
      declare -i ctr=0
      echo -n " $pno "
      while [ $ctr -le $MAXWAIT ]; do
        echo "quit" | nc $NCPROXY -w 2 ${FLOATS[$JHNO]} $pno >/dev/null 2>&1 && break
        echo -n "."
        sleep 2
        let ctr+=1
      done
      if [ $ctr -ge $MAXWAIT ]; then echo -ne " $RED timeout $NORM"; let waiterr+=1; fi
      MAXWAIT=30
    done
    MAXWAIT=60
  done
  if test $waiterr == 0; then echo "OK"; else echo "RET $waiterr"; fi
  return $waiterr
}

# Test ssh and test for user_data (or just plain ls) and internet ping (via SNAT instance)
# $1 => Keypair
# $2 => IP
# $3 => Port
# $4 => NUMBER
# RC: 2 => ls or user_data injection failed
#     1 => ping failed
testlsandping()
{
  unset SSH_AUTH_SOCK
  if test -z "$3" -o "$3" = "22"; then
    unset pport
    ssh-keygen -R $2 -f ~/.ssh/known_hosts >/dev/null 2>&1
  else
    pport="-p $3"
    ssh-keygen -R [$2]:$3 -f ~/.ssh/known_hosts >/dev/null 2>&1
  fi
  if test -z "$pport"; then
    # no user_data on JumpHosts
    ssh -i $1.pem $pport -o "StrictHostKeyChecking=no" -o "ConnectTimeout=12" linux@$2 ls >/dev/null 2>&1 || return 2
  else
    # Test whether user_data file injection worked
    if test -n "$BOOTALLATONCE"; then
      # no indiv user data per VM when mass booting ...
      ssh -i $1.pem $pport -o "StrictHostKeyChecking=no" -o "ConnectTimeout=12" linux@$2 grep api_monitor.sh.$$ /tmp/testfile >/dev/null 2>&1 || return 2
    else
      ssh -i $1.pem $pport -o "StrictHostKeyChecking=no" -o "ConnectTimeout=12" linux@$2 grep api_monitor.sh.$$.$4 /tmp/testfile >/dev/null 2>&1 || return 2
    fi
  fi
  PING=$(ssh -i $1.pem $pport -o "StrictHostKeyChecking=no" -o "ConnectTimeout=6" linux@$2 ping -c1 $PINGTARGET 2>/dev/null | tail -n2; exit ${PIPESTATUS[0]})
  if test $? = 0; then echo $PING; return 0; fi
  sleep 1
  PING=$(ssh -i $1.pem $pport -o "StrictHostKeyChecking=no" -o "ConnectTimeout=6" linux@$2 ping -c1 $PINGTARGET2 2>&1 | tail -n2; exit ${PIPESTATUS[0]})
  RC=$?
  echo "$PING"
  if test $RC != 0; then return 1; else return 0; fi
}

# Test internet access of JumpHosts (via ssh)
testjhinet()
{
  local RC R JHNO
  unset SSH_AUTH_SOCK
  ERR=""
  #echo "Test JH access and outgoing inet ... "
  declare -i RC=0
  for JHNO in $(seq 0 $(($NOAZS-1))); do
    echo -n "Access JH$JHNO (${FLOATS[$JHNO]}): "
    testlsandping ${KEYPAIRS[0]} ${FLOATS[$JHNO]}
    R=$?
    if test $R == 2; then
      RC=2; ERR="${ERR}ssh JH$JHNO ls; "
    elif test $R == 1; then
      let CUMPINGERRORS+=1; ERR="${ERR}ssh JH$JHNO ping $PINGTARGET || ping $PINGTARGET2; "
    fi
  done
  if test $RC = 0; then echo -e "$GREEN SUCCESS $NORM"; else echo -e "$RED FAIL $ERR $NORM"; return $RC; fi
  if test -n "$ERR"; then echo -e "$RED $ERR $NORM"; fi
}

# Test VM access (fwdmasq) and outgoing SNAT inet on all VMs
testsnat()
{
  local FAIL ERRJH pno RC JHNO
  unset SSH_AUTH_SOCK
  ERR=""
  ERRJH=()
  declare -i FAIL=0
  for JHNO in $(seq 0 $(($NOAZS-1))); do
    declare -i no=$JHNO
    for red in ${REDIRS[$JHNO]}; do
      pno=${red#*tcp,}
      pno=${pno%%,*}
      testlsandping ${KEYPAIRS[1]} ${FLOATS[$JHNO]} $pno $no
      RC=$?
      let no+=$NOAZS
      if test $RC == 2; then
        ERRJH[$JHNO]="${ERRJH[$JHNO]}$red "
      elif test $RC == 1; then
        let PINGERRORS+=1
        ERR="${ERR}ssh VM$JHNO $red ping $PINGTARGET || ping $PINGTARGET2; "
      fi
    done
  done
  if test ${#ERRJH[*]} != 0; then echo -e "$RED $ERR $NORM"; ERR=""; sleep 12; fi
  # Process errors: Retry
  # FIXME: Is it actually worth retrying? Does it really improve the results?
  for JHNO in $(seq 0 $(($NOAZS-1))); do
    no=$JHNO
    for red in ${ERRJH[$JHNO]}; do
      pno=${red#*tcp,}
      pno=${pno%%,*}
      testlsandping ${KEYPAIRS[1]} ${FLOATS[$JHNO]} $pno $no
      RC=$?
      let no+=$NOAZS
      if test $RC == 2; then
        let FAIL+=2
        ERR="${ERR}(2)ssh VM$JHNO $red ls; "
      elif test $RC == 1; then
        let PINGERRORS+=1
        ERR="${ERR}(2)ssh VM$JHNO $red ping $PINGTARGET || ping $PINGTARGET2; "
      fi
    done
  done
  if test -n "$ERR"; then echo -e "$RED $ERR ($FAIL) $NORM"; fi
  if test ${#ERRJH[*]} != 0; then
    echo -en "$BOLD RETRIED: "
    for JHNO in $(seq 0 $(($NOAZS-1))); do
      test -n "${ERRJH[$JHNO]}" && echo -n "$JHNO: ${ERRJH[$JHNO]} "
    done
    echo -e "$NORM"
  fi
  return $FAIL
}


# [-m] STATLIST [DIGITS [NAME]]
# m for machine readable
stats()
{
  local NM NO VAL LIST DIG OLDIFS SLIST MIN MAX MID MED NFQ NFQL NFQR NFQF NFP AVGC AVG
  if test "$1" = "-m"; then MACHINE=1; shift; else unset MACHINE; fi
  # Fixup "{" found after errors in time stats
  NM=$1
  NO=$(eval echo "\${#${NM}[@]}")
  for idx in `seq 0 $(($NO-1))`; do
    VAL=$(eval echo \${${NM}[$idx]})
    if test "$VAL" = "{"; then eval $NM[$idx]=1.00; fi
  done
  # Display name
  if test -n "$3"; then NAME=$3; else NAME=$1; fi
  # Generate list and sorted list
  eval LIST=( \"\${${1}[@]}\" )
  if test -z "${LIST[*]}"; then return; fi
  DIG=${2:-2}
  OLDIFS="$IFS"
  IFS=$'\n' SLIST=($(sort -n <<<"${LIST[*]}"))
  IFS="$OLDIFS"
  #echo ${SLIST[*]}
  NO=${#SLIST[@]}
  # Some easy stats, Min, Max, Med, Avg, 95% quantile ...
  MIN=${SLIST[0]}
  MAX=${SLIST[-1]}
  MID=$(($NO/2))
  if test $(($NO%2)) = 1; then MED=${SLIST[$MID]};
  else MED=`python -c "print \"%.${DIG}f\" % ((${SLIST[$MID]}+${SLIST[$(($MID-1))]})/2)"`
  fi
  NFQ=$(scale=3; echo "(($NO-1)*95)/100" | bc -l)
  NFQL=${NFQ%.*}; NFQR=$((NFQL+1)); NFQF=0.${NFQ#*.}
  #echo "DEBUG 95%: $NFQ $NFQL $NFR $NFQF"
  if test $NO = 1; then NFP=${SLIST[$NFQL]}; else
    NFP=`python -c "print \"%.${DIG}f\" % (${SLIST[$NFQL]}*(1-$NFQF)+${SLIST[$NFQR]}*$NFQF)"`
  fi
  AVGC="($(echo ${SLIST[*]}|sed 's/ /+/g'))/$NO"
  #echo "$AVGC"
  #AVG=`python -c "print \"%.${DIG}f\" % ($AVGC)"`
  AVG=$(echo "scale=$DIG; $AVGC" | bc -l)
  if test -n "$MACHINE"; then
    echo "#$NM: $NO|$MIN|$MED|$AVG|$NFP|$MAX" | tee -a $LOGFILE
  else
    echo "$NAME: Num $NO Min $MIN Med $MED Avg $AVG 95% $NFP Max $MAX" | tee -a $LOGFILE
  fi
}

# [-m] for machine readable
allstats()
{
 stats $1 NETSTATS   2 "Neutron API Stats "
 stats $1 FIPSTATS   2 "Neutron FIP Stats "
 stats $1 NOVASTATS  2 "Nova API Stats    "
 stats $1 NOVABSTATS 2 "Nova Boot Stats   "
 stats $1 VMCSTATS   0 "VM Creation Stats "
 stats $1 VMDSTATS   0 "VM Deletion Stats "
 stats $1 VOLSTATS   2 "Cinder API Stats  "
 stats $1 VOLCSTATS  0 "Vol Creation Stats"
 stats $1 WAITTIME   0 "Wait for VM Stats "
 stats $1 TOTTIME    0 "Total setup Stats "
}

# Helper to find a resource ...
findres()
{
  local FILT=${1:-$RPRE}
  shift
  # FIXME: Add timeout handling
  $@ 2>/dev/null | grep " $FILT" | sed 's/^| \([0-9a-f-]*\) .*$/\1/'
}

cleanup()
{
  VMS=( $(findres ${RPRE}VM_VM nova list) )
  deleteVMs
  ROUTERS=( $(findres "" neutron router-list) )
  SNATROUTE=1
  #FIPS=( $(findres "" neutron floatingip-list) )
  FIPS=( $(neutron floatingip-list | grep '10\.250\.' | sed 's/^| *\([^ ]*\) *|.*$/\1/') )
  deleteFIPs
  JHVMS=( $(findres ${RPRE}VM_JH nova list) )
  deleteJHVMs
  KEYPAIRS=( $(nova keypair-list | grep $RPRE | sed 's/^| *\([^ ]*\) *|.*$/\1/') )
  deleteKeypairs
  VIPS=( $(findres ${RPRE}VirtualIP neutron port-list) )
  deleteVIPs
  VOLUMES=( $(findres ${RPRE}RootVol_VM cinder list) )
  waitdelVMs; deleteVols
  JHVOLUMES=( $(findres ${RPRE}RootVol_JH cinder list) )
  waitdelJHVMs; deleteJHVols
  PORTS=( $(findres ${RPRE}Port_VM neutron port-list) )
  JHPORTS=( $(findres ${RPRE}Port_JH neutron port-list) )
  deletePorts; deleteJHPorts	# not strictly needed, ports are del by VM del
  SGROUPS=( $(findres "" neutron security-group-list) )
  deleteSGroups
  SUBNETS=( $(findres "" neutron subnet-list) )
  deleteRIfaces
  deleteSubNets
  NETS=( $(findres "" neutron net-list) )
  deleteNets
  deleteRouters
}

# Network cleanups can fail if VM deletion failed, so cleanup again
# and wait until networks have disappeared
waitnetgone()
{	
  local DVMS DFIPS DJHVMS DKPS VOLS DJHVOLS
  # Cleanup: These really should not exist
  VMS=( $(findres ${RPRE}VM_VM nova list) ); DVMS=(${VMS[*]})
  deleteVMs
  ROUTERS=( $(findres "" neutron router-list) )
  # Floating IPs don't have a name and are thus hard to associate with us
  if test -n "${OLDFIPS[*]}"; then
    OFFILT=$(echo "\\(${OLDFIPS[*]}\\)" | sed 's@ @\\|@g')
    FIPS=( $(neutron floatingip-list | grep "$OFFILT") )
  else
    FIPS=( $(neutron floatingip-list | grep '10\.250\.' | sed 's/^| *\([^ ]*\) *|.*$/\1/') )
  fi
  DFIPS=(${FIPS[*]})
  deleteFIPs
  JHVMS=( $(findres ${RPRE}VM_JH nova list) ); DJHVMS=(${JHVMS[*]})
  deleteJHVMs
  KEYPAIRS=( $(nova keypair-list | grep $RPRE | sed 's/^| *\([^ ]*\) *|.*$/\1/') ); DKPS=(${KEYPAIRS[*]})
  deleteKeypairs
  VOLUMES=( $(findres ${RPRE}RootVol_VM cinder list) ); DVOLS=(${VOLUMES[*]})
  waitdelVMs; deleteVols
  JHVOLUMES=( $(findres ${RPRE}RootVol_JH cinder list) ); DJHVOLS=(${JHVOLUMES[*]})
  waitdelJHVMs; deleteJHVols
  if test -n "$DVMS$DFIPS$DJHVMS$DKPS$DVOL$DJHVOLS"; then
    echo -e "${YELLOW}ERROR: Found VMs $DVMS FIPs $DFIPS JHVMs $DJHVMS Keypairs $DKPS Volumes $DVOLS JHVols $DJHVOLS\n VMs $REMVMS FIPS $REMFIPS JHVMs $REMHJVMS Keypairs $REMKPS Volumes $REMVOLS JHVols $REMJHVOLS$NORM" 1>&2
    sendalarm 1 Cleanup "Found VMs $DVMS FIPs $DFIPS JHVMs $DJHVMS Keypairs $DKPS Volumes $DVOLS JHVols $DJHVOLS
 VMs $REMVMS FIPs $REMFIPS JHVMs $REMJHVMS Keypairs $REMKPS Volumes $REMVOLS JHVols $REMJHVOLS" 0
  fi
  # Cleanup: These might be left over ...
  local to
  declare -i to=0
  # There should not be anything left ...
  PORTS=( $(findres "" neutron port-list) )
  IGNORE_ERRORS=1
  deletePorts
  unset IGNORE_ERRORS
  echo -n "Wait for subnets/nets to disappear: "
  while test $to -lt 40; do
    SUBNETS=( $(findres "" neutron subnet-list) )
    NETS=( $(findres "" neutron net-list) )
    if test -z "${SUBNETS[*]}" -a -z "${NETS[*]}"; then echo "gone"; return; fi
    sleep 2
    let to+=1
    echo -n "."
  done
  SGROUPS=( $(findres "" neutron security-group-list) )
  ROUTERS=( $(findres "" neutron router-list) )
  IGNORE_ERRORS=1
  deleteSGroups
  if test -n "$ROUTERS"; then deleteRIfaces; fi
  deleteSubNets
  deleteNets
  if test -n "$ROUTERS"; then deleteRouters; fi
  unset IGNORE_ERRORS
}

# Clean/Delete old OpenStack project
cleanprj()
{
  if test ${#OS_PROJECT_NAME} -le 5; then echo -e "${YELLOW}ERROR: Won't delete $OS_PROJECT_NAME$NORM" 1>&2; return 1; fi
  #TODO: Wait for resources being gone
  sleep 10
  otc.sh iam deleteproject $OS_PROJECT_NAME 2>/dev/null || otc.sh iam cleanproject $OS_PROJECT_NAME
  echo -e "${REV}Note: Removed Project $OS_PROJECT_NAME ($?)${NORM}"
}

# Create a new OpenStack project
createnewprj()
{
  # First cleanup old project
  if test "$RUNS" != 0; then cleanprj; fi
  PRJNO=$(($RUNS/$REFRESHPRJ))
  OS_PROJECT_NAME=${OS_PROJECT_NAME:0:5}_APIMonitor_$$_$PRJNO
  unset OS_PROJECT_ID
  otc.sh iam createproject $OS_PROJECT_NAME >/dev/null
  echo -e "${REV}Note: Created project $OS_PROJECT_NAME ($?)$NORM"
  sleep 10
}

# Allow for many recipients
parse_notification_addresses()
{
  # Parses from Environment
  # API_MONITOR_ALARM_EMAIL_[0-9]+         # email address
  # API_MONITOR_NOTE_EMAIL_[0-9]+          # email address
  # API_MONITOR_ALARM_MOBILE_NUMBER_[0-9]+ # international mobile number
  # API_MONITOR_NOTE_MOBILE_NUMBER_[0-9]+  # international mobile number

  # Sets global array with values from enironment variables:
  # ${ALARM_EMAIL_ADDRESSES[@]}
  # ${NOTE_EMAIL_ADDRESSES[@]}
  # ${ALARM_MOBILE_NUMBERS[@]}
  # ${NOTE_MOBILE_NUMBERS[@]}

  for env_name in $(env | egrep API_MONITOR_ALARM_EMAIL\(_[0-9]+\)? | sed 's/^\([^=]*\)=.*/\1/')
  do
    ALARM_EMAIL_ADDRESSES=("${ALARM_EMAIL_ADDRESSES[@]}" ${!env_name})
  done

  for env_name in $(env | egrep API_MONITOR_NOTE_EMAIL\(_[0-9]+\)? | sed 's/^\([^=]*\)=.*/\1/')
  do
    NOTE_EMAIL_ADDRESSES=("${NOTE_EMAIL_ADDRESSES[@]}" ${!env_name})
  done

  for env_name in $(env | egrep API_MONITOR_ALARM_MOBILE_NUMBER\(_[0-9]+\)? | sed 's/^\([^=]*\)=.*/\1/')
  do
    ALARM_MOBILE_NUMBERS=("${ALARM_MOBILE_NUMBERS[@]}" ${!env_name})
  done

  for env_name in $(env | egrep API_MONITOR_NOTE_MOBILE_NUMBER\(_[0-9]+\)? | sed 's/^\([^=]*\)=.*/\1/')
  do
    NOTE_MOBILE_NUMBERS=("${NOTE_MOBILE_NUMBERS[@]}" ${!env_name})
  done
}

parse_notification_addresses

declare -i loop=0

# Statistics
# API performance neutron, cinder, nova
declare -a NETSTATS
declare -a FIPSTATS
declare -a VOLSTATS
declare -a NOVASTATS
declare -a NOVABSTATS
# Resource creation stats (creation/deletion)
declare -a VOLCSTATS
declare -a VOLDSTATS
declare -a VMCSTATS
declare -a VMCDTATS

declare -a TOTTIME
declare -a WAITTIME

declare -i CUMPINGERRORS=0
declare -i CUMAPIERRORS=0
declare -i CUMAPITIMEOUTS=0
declare -i CUMAPICALLS=0
declare -i CUMVMERRORS=0
declare -i CUMWAITERRORS=0
declare -i CUMVMS=0
declare -i RUNS=0
declare -i SUCCRUNS=0

LASTDATE=$(date +%Y-%m-%d)
LASTTIME=$(date +%H:%M:%S)

# MAIN LOOP
while test $loop != $MAXITER; do

declare -i PINGERRORS=0
declare -i APIERRORS=0
declare -i APITIMEOUTS=0
declare -i VMERRORS=0
declare -i WAITERRORS=0
declare -i APICALLS=0
declare -i ROUNDVMS=0

# Arrays to store resource creation start times
declare -a VOLSTIME=()
declare -a JVOLSTIME=()
declare -a VMSTIME=()
declare -a JVMSTIME=()

# List of resources - neutron
declare -a ROUTERS=()
declare -a NETS=()
declare -a SUBNETS=()
declare -a JHNETS=()
declare -a JHSUBNETS=()
declare -a SGROUPS=()
declare -a JHPORTS=()
declare -a PORTS=()
declare -a VIPS=()
declare -a FIPS=()
declare -a FLOATS=()
# cinder
declare -a JHVOLUMES=()
declare -a VOLUMES=()
# nova
declare -a KEYPAIRS=()
declare -a VMS=()
declare -a JHVMS=()
SNATROUTE=""

# Main
MSTART=$(date +%s)
# Debugging: Start with volume step
if test "$1" = "CLEANUP"; then
  if test -n "$2"; then RPRE=$2; fi
  echo -e "$BOLD *** Start cleanup $RPRE *** $NORM"
  cleanup
  echo -e "$BOLD *** Cleanup complete *** $NORM"
  exit 0
else # test "$1" = "DEPLOY"; then
 if test "$REFRESHPRJ" != 0 && test $(($RUNS%$REFRESHPRJ)) == 0; then createnewprj; fi
 # Complete setup
 echo -e "$BOLD *** Start deployment $NOAZS SNAT JumpHosts + $NOVMS VMs *** $NORM"
 date
 # Image IDs
 JHIMGID=$(ostackcmd_search $JHIMG $GLANCETIMEOUT glance image-list $JHIMGFILT | awk '{ print $2; }')
 if test -z "$JHIMGID"; then sendalarm 1 "No JH image $JHIMG found, aborting." "" $GLANCETIMEOUT; exit 1; fi
 IMGID=$(ostackcmd_search $IMG $GLANCETIMEOUT glance image-list $IMGFILT | awk '{ print $2; }')
 if test -z "$IMGID"; then sendalarm 1 "No image $IMG found, aborting." "" $GLANCETIMEOUT; exit 1; fi
 let APICALLS+=2
 # Retrieve root volume size
 OR=$(ostackcmd_id min_disk $GLANCETIMEOUT glance image-show $JHIMGID)
 if test $? != 0; then
  let APIERRORS+=1; sendalarm 1 "glance image-show failed" "" $GLANCETIMEOUT
 else
  read TM SZ <<<"$OR"
  JHVOLSIZE=$(($SZ+$ADDJHVOLSIZE))
 fi
 OR=$(ostackcmd_id min_disk $GLANCETIMEOUT glance image-show $IMGID)
 if test $? != 0; then
  let APIERRORS+=1; sendalarm 1 "glance image-show failed" "" $GLANCETIMEOUT
 else
  read TM SZ <<<"$OR"
  VOLSIZE=$(($SZ+$ADDVMVOLSIZE))
 fi
 let APICALLS+=2
 #echo "Image $IMGID $VOLSIZE $JHIMGID $JHVOLSIZE"; exit 0;
 if createRouters; then
  if createNets; then
   if createSubNets; then
    if createRIfaces; then
     if createSGroups; then
      if createVIPs; then
       if createJHVols; then
        if createJHPorts; then
         if createVols; then
          if createKeypairs; then
           createPorts
           waitJHVols
           if createJHVMs; then
            let ROUNDVMS=$NOAZS
            if createFIPs; then
             waitVols
             if createVMs; then
              let ROUNDVMS+=$NOVMS
              waitJHVMs
              waitVMs
              setmetaVMs
              setPortForward
              WSTART=$(date +%s)
              wait222
              WAITERRORS=$?
              testjhinet
              RC=$?
              if test $RC != 0; then
                let VMERRORS+=$RC
                sendalarm $RC "$ERR" "" $((4*$MAXWAIT))
                errwait $VMERRWAIT
              fi
              testsnat
              RC=$?
              let VMERRORS+=$((RC/2))
              if test $RC != 0; then
                sendalarm $RC "$ERR" "" $((4*$MAXWAIT))
                errwait $VMERRWAIT
              fi
              # TODO: Create disk ... and attach to JH VMs ... and test access
              # TODO: Attach additional net interfaces to JHs ... and test IP addr
              MSTOP=$(date +%s)
              WAITTIME+=($(($MSTOP-$WSTART)))
              echo -e "$BOLD *** SETUP DONE ($(($MSTOP-$MSTART))s), DELETE AGAIN $NORM"
              let SUCCRUNS+=1
              sleep 5
              #read ANS
              # Subtract waiting time (5s here)
              MSTART=$(($MSTART+$(date +%s)-$MSTOP))
              # TODO: Detach and delete disks again
             fi; deleteVMs
            fi; deleteFIPs
           fi; deleteJHVMs
          fi; deleteKeypairs
         fi; waitdelVMs; deleteVols
        fi; waitdelJHVMs
        #echo -e "${BOLD}Ignore port del errors; VM cleanup took care already.${NORM}"
        #IGNORE_ERRORS=1
        #deletePorts; deleteJHPorts	# not strictly needed, ports are del by VM del
        #unset IGNORE_ERRORS
       fi; deleteJHVols
      fi; deleteVIPs
     # There is a chance that some VMs were not created, but ports were allocated, so clean ...
     fi; cleanupPorts; deleteSGroups
    fi; deleteRIfaces
   fi; deleteSubNets
  fi; deleteNets
 fi; deleteRouters
 #echo "${NETSTATS[*]}"
 echo -e "$BOLD *** Cleanup complete *** $NORM"
 THISRUNTIME=$(($(date +%s)-$MSTART))
 TOTTIME+=($THISRUNTIME)
 # Raise an alarm if we have not yet sent one and we're very slow despite this
 if test -n "$BOOTALLATONCE"; then LIN=500; FACT=20; else LIN=484; FACT=32; fi
 if test $VMERRORS = 0 -a $WAITERRORS = 0 -a $THISRUNTIME -gt $(($LIN+$FACT*$NOVMS)); then
    sendalarm 1 "SLOW PERFORMANCE" "Cycle time: $THISRUNTIME" $(($LIN+$FACT*$NOVMS))
    #waiterr $WAITERR
 fi
 allstats
 echo "This run: Overall $ROUNDVMS / ($NOVMS + $NOAZS) VMs, $APICALLS API calls: $(($(date +%s)-$MSTART))s, $VMERRORS VM login errors, $WAITERRORS VM timeouts, $APIERRORS API errors (of which $APITIMEOUTS API timeouts), $PINGERRORS Ping Errors, $(date +'%Y-%m-%d %H:%M:%S %Z')"
#else
#  usage
fi
let CUMAPIERRORS+=$APIERRORS
let CUMAPITIMEOUTS+=$APITIMEOUTS
let CUMVMERRORS+=$VMERRORS
let CUMPINGERRORS+=$PINGERRORS
let CUMWAITERRORS+=$WAITERRORS
let CUMAPICALLS+=$APICALLS
let CUMVMS+=$ROUNDVMS
let RUNS+=1

CDATE=$(date +%Y-%m-%d)
CTIME=$(date +%H:%M:%S)
if test -n "$SENDSTATS" -a "$CDATE" != "$LASTDATE" || test $(($loop+1)) == $MAXITER; then
  sendalarm 0 "Statistics for $LASTDATE $LASTTIME - $CDATE $CTIME" "
$RPRE $VERSION on $(hostname) testing $SHORT_DOMAIN/$OS_PROJECT_NAME:

$RUNS deployments ($SUCCRUNS successful, $CUMVMS/$(($RUNS*($NOAZS+$NOVMS))) VMs, $CUMAPICALLS API calls)
$CUMVMERRORS VM LOGIN ERRORS
$CUMWAITERRORS VM TIMEOUT ERRORS
$CUMAPIERRORS API ERRORS
$CUMAPITIMEOUTS API TIMEOUTS
$CUMPINGERRORS Ping failures

$(allstats)

#TEST: $SHORT_DOMAIN|$VERSION|$RPRE|$(hostname)|$OS_PROJECT_NAME
#STAT: $LASTDATE|$LASTTIME|$CDATE|$CTIME
#RUN: $RUNS|$SUCCRUNS|$CUMVMS|$((($NOAZS+$NOVMS)*$RUNS))|$CUMAPICALLS
#ERRORS: $CUMVMERRORS|$CUMWAITERRORS|$CUMAPIERRORS|$APITIMEOUTS|$CUMPINGERRORS
$(allstats -m)
" 0
  echo "#TEST: $SHORT_DOMAIN|$VERSION|$RPRE|$(hostname)|$OS_PROJECT_NAME
#STAT: $LASTDATE|$LASTTIME|$CDATE|$CTIME
#RUN: $RUNS|$CUMVMS|$CUMAPICALLS
#ERRORS: $CUMVMERRORS|$CUMWAITERRORS|$CUMAPIERRORS|$APITIMEOUTS|$CUMPINGERRORS
$(allstats -m)" > Stats.$LASTDATA.$LASTTIME.$CDATE.$CTIME.psv
  CUMVMERRORS=0
  CUMAPIERRORS=0
  CUMAPITIMEOUTS=0
  CUMPINGERRORS=0
  CUMWAITERRORS=0
  CUMAPICALLS=0
  LASTDATE="$CDATE"
  LASTTIME="$CTIME"
  RUNS=0
  # Reset stats
  NETSTATS=()
  FIPSTATS=()
  VOLSTATS=()
  NOVASTATS=()
  NOVABSTATS=()
  VOLCSTATS=()
  VOLDSTATS=()
  VMCSTATS=()
  VMDSTATS=()
  TOTTIME=()
  WAITTIME=()
fi

# TODO: Clean up residuals, if any
waitnetgone
let loop+=1
done
rm -f ${RPRE}Keypair_JH.pem ${RPRE}Keypair_VM.pem
if test "$REFRESHPRJ" != 0; then cleanprj; fi
