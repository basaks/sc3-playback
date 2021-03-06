#!/bin/bash

PLAYBACKROOT="$( dirname "$( readlink -f "$0")")/"
MAKEMSEEDPLAYBACK="${PLAYBACKROOT}/make-mseed-playback.py"
RUNPLAYBACK="${PLAYBACKROOT}/playback.py"
PLAYBACKDATA="${PLAYBACKROOT}/data"
PREPARATION="false"
PLAYBACK="false"
INVENTORY="inventory.xml"
CONFIG="config.xml"
CONFIGDIR="${HOME}/.seiscomp3"
EVENTID=""
BEGIN=""
END=""
FILEIN=""
ACTION=""
MODE="historic"
DELAYS=""

function loadsconf(){
    if [ -f "$CONFIGFILE" ]; then # deepest but does not prevails over the over
        echo Loading $CONFIGFILE ...
        source "$CONFIGFILE" || (echo Can t load configuration in $CONFIGFILE && exit 1)
	export SEISCOMP_ROOT=$SEISCOMP_ROOT
	export LD_LIBRARY_PATH="$SEISCOMP_ROOT/lib:$LD_LIBRARY_PATH"
	export PYTHONPATH="$SEISCOMP_ROOT/lib/python:$PYTHONPATH"
	export MANPATH="$SEISCOMP_ROOT/man:$MANPATH"
	export PATH="$SEISCOMP_ROOT/bin:$PATH"
    fi
}

function usage(){
cat <<EOF
Usage: $0 [Options] action 

Arguments:
    action          Decide what to do:
                      prep: Prepare playback files
                      pb: run playback (requires a previous 'prep')
                      all: do both in one go 
Options:
    -h              Show this message.
    --config-file   Use alternative playback configuration file. If none
                    given follows default loading order:
                        1- $SEISCOMPROOT/etc/playback.cfg
                        2- ~/.seiscomp3/playback.cfg (prevails previous)
                        3- ./playback.cfg (prevails all previous)
    --configdir     SeisComP3 configuration directory to use. (Default: 
                    ${HOME}/.seiscomp3).

  Event IDs:
    --evid          Give an eventID for playback.
    --fin           Give a file with one eventID per line for playback.
    
  Time window
    --begin         Give the starttime of a playback time window. Note that 
                    these options are mutually exclusive with the Event ID 
                    options.
    --end           Give the endtime of a playback time window. Note that these
                    options are mutually exclusive with the Event ID options.
                    
  Playback
    --mode          Choose between 'realtime', 'historic' and 'offline'. For 'realtime' 
		    the records in the input file will get a new timestamp relative 
                    to the current system time at startup. For 'historic' the 
                    input records will keep their original timestamp. For 'offline'
                    each enabled module is ran with their builtin parametric playback
		    as fast as possible, not respecting the timestamp of records.  
                    (Default: 'historic')
    --delaytbl      Pass the path to an ascii file containing the average delays
                    for every station in the network as well as a default delay
                    that is applied to each station that is not explicitly 
                    listed. The format of the file is as follows:
                    
                    default: 2.0
                    CH.AIGLE: 5.2
                    CH.VANNI: 3.5
                    ...
EOF
}

function processinput(){
if [ -n "$EVENTID" ] && [ $EVENTID != "none" ] ; then
	if [ -n "$BEGIN" ] || [ -n "$END" ]; then
		echo "You can only use event IDs OR time windows."
		usage
		exit 1
	fi
fi
	
if [ -z "$EVENTID" ] && [ -z "$FILEIN" ]; then
	if [ -z "$BEGIN" ] || [ -z "$END" ]; then
		echo "Either chose an event ID or a time window with start and end time."
		usage
		exit 1
	fi
fi

if [ -n "$EVENTID" ] && [ -n "$FILEIN" ] && [ $EVENTID != "none" ] ; then
	echo "Please define event IDs either in a file OR on the command line."
	usage
	exit 1		
fi

if [ -z "$ACTION" ]; then
	echo "Please define an action."
	usage
	exit 1
fi

if [ -n "$DELAYTBL" ]; then
	DELAYS="-d ${DELAYTBL}"
fi

if [ -n "$FILEIN" ]; then
	index=0
	my_re="^#"
	while read line; do
		if [[ ! $line =~ $my_re ]]; then
			evids[$index]=$line
			((index++))
		fi
	done < $FILEIN
	TMP=`basename ${FILEIN}`
	PBDIR=${PLAYBACKDATA}/${TMP%\.*}
	if [ ! -d "$PBDIR" ]; then
		mkdir -p "$PBDIR"
	fi
fi

if [ -n "$EVENTID" ] ; then
	evids[0]=$EVENTID
	# get the last part of the event ID and use it to name the output 
	# directory
	PBDIR=${PLAYBACKDATA}/${EVENTID##*/}
	if [ ! -d "$PBDIR" ]; then
		mkdir -p "$PBDIR"
	fi
	
fi

if [ -n "$BEGIN" ] && [ -n "$END" ]; then
	
	evids=()
	evids=( $( seiscomp exec scevtls  ${DBCONN}  --begin "$BEGIN"  --end "$END" ) )
	echo ${#evids[@]} "events in requested time span (from "$BEGIN" to "$END")"	
	
	PBDIR=${PLAYBACKDATA}/${BEGIN//[!0-9]/}-${END//[!0-9]/}
    #_${#evids[@]}_events  
	if [ ! -d "$PBDIR" ]; then
		mkdir -p "$PBDIR"
	fi	
	echo "data files in " $PBDIR 
	
fi

if [ "$MODE" != "historic" ] && [ "$MODE" != "realtime" ] && [ "$MODE" != "offline" ]; then
	echo "Playback mode has to be either 'historic' or 'realtime' or 'offline."
	usage
	exit 1
fi

if [ "$MODE" == "offline" ] && [ "$1" == "pb"] ; then
	echo Offline playback not yet implemented
	usage
	exit 1
fi

if [ ${ACTION} == "prep" ]; then
	PREPARATION="true"
elif [ ${ACTION} == "pb" ]; then
	PLAYBACK="true"
elif [ ${ACTION} == "all" ]; then
	PREPARATION="true"
	PLAYBACK="true"
else
	echo "action has to be one of 'prep', 'pb', 'all'"
	usage
	exit 1
fi

}

function setupdb(){
	if [ -n "$FILEIN" ] ||  [ -n "$EVENTID" ] ; then
		for TMPID in ${evids[@]}; do
			EVENTNAME=${TMPID##*/}
			echo "Retrieving event information for ${TMPID} ..."
			scxmldump --debug -f -E ${TMPID} -P -A -M -F ${DBCONN} > ${EVENTNAME}.xml
		done
	else
		EVENTNAME=${#evids[@]}_events 
		EVENTSIDLIST=""
		for TMPID in ${evids[@]}; do
			EVENTSIDLIST=$EVENTSIDLIST,$TMPID
		done
		echo "Retrieving event information for ${EVENTNAME} ..."
		echo scxmldump --debug -f -E "${EVENTSIDLIST}" -P -A -M -F ${DBCONN}
		scxmldump --debug -f -E "${EVENTSIDLIST}" -P -A -M -F ${DBCONN} > ${EVENTNAME}.xml
	fi
	echo "Retrieving inventory ..."
	scxmldump -f -I $DBCONN  > $INVENTORY
	echo "Retrieving configuration ..."
	scxmldump -f -C $DBCONN  > $CONFIG
	echo "Initializing sqlite database ..."
	if [ -f "${PBDB}" ]; then
		rm "${PBDB}"
	fi
	sqlite3 -batch -init "$SQLITEINIT" "$PBDB" .exit
   	echo "Populating sqlite database ..."
	scdb --plugins dbsqlite3 -d "sqlite3://${PBDB}" -i $INVENTORY
	scdb --plugins dbsqlite3 -d "sqlite3://${PBDB}" -i $CONFIG
	cp "${PBDB}" "${PBDB%\.*}_no_event.sqlite" 
}

if [ "$#" -gt 7 ] || [ $# -lt 3 ]; then
	echo "Too few command line arguments."
    usage
    exit 0
fi

# Processing command line options
while [ $# -gt 1 ]
do
	case "$1" in 
		--evid) EVENTID="$2";shift;;
		--begin) BEGIN="$2";shift;;
		--end) END="$2";shift;;
		--configdir) CONFIGDIR="$2";shift;;
		--fin) FILEIN="$2"; shift;;
		--config-file) CONFIGFILE="$2";shift;;
		--mode) MODE="$2"; shift;;
		--delaytbl) DELAYTBL="$2";shift;;
		-h) usage; exit 0;;
		-*) usage			
			exit 1;;
		*) break;;
	esac
	shift	
done

ACTION=$1

if [ -f "$CONFIGFILE" ] ; then
	loadsconf
else
	# loading order 
	#CONFIGFILE="${PLAYBACKROOT}playback.cfg" # deepest but does not prevails over the over
	#loadsconf
	CONFIGFILE="${SEISCOMP_ROOT}/etc/playback.cfg" # deepest but does not prevails over the over 
	loadsconf
	CONFIGFILE="${HOME}/.seiscomp3/playback.cfg" # prevails over the previous
	loadsconf
	CONFIGFILE="./playback.cfg" #  prevails over all the overs
	loadsconf
fi

processinput
if [ ! -f "$MAKEMSEEDPLAYBACK" ] || [ ! -f "$RUNPLAYBACK" ]; then
	echo "You need the following dependencies:" 
	echo $MAKEMSEEDPLAYBACK 
	echo $RUNPLAYBACK
	exit 1
fi

if [ $PREPARATION != "false" ]
then
	echo "Preparing playback files ..."
	cd "$PBDIR"
	if [ "$MODE" != "offline" ]
	then
		setupdb
	fi
	
	${SEISCOMP_ROOT}/bin/seiscomp check spread
	# if no event requested, then one miniseed file for whole time span 
	if [ -z "$EVENTID" ] && [ -z "$FILEIN" ] 
	then
        	"$MAKEMSEEDPLAYBACK"  -u playback -H ${HOST} ${DBCONN} --debug --start ${BEGIN/ /T} --end ${END/ /T}  -I "${RECORDURL}"
		echo "Examine data with:"
		echo "scrttv --debug --offline --record-file ${PBDIR}/*sorted-mseed"
	
	# otherwise process requested events individually 
	else 
		for TMPID in ${evids[@]}
		do
			"$MAKEMSEEDPLAYBACK"  -u playback -H ${HOST} ${DBCONN} -E ${TMPID} -I "${RECORDURL}" 
			#"sdsarchive://${SDSARCHIVE}"
			echo "Examine data with:"
			echo "scrttv --debug --offline --record-file \"${PBDIR}/${TMPID}\"*.sorted-mseed"
		done
	fi
	cd -
fi

if [ $PLAYBACK != "false" ]
then
	# prepare new db
	echo "Running playback ..."
	echo cp ${PBDIR}/${PBDB%\.*}_no_event.sqlite ${PBDIR}/${PBDB}
	cp "${PBDIR}/${PBDB%\.*}_no_event.sqlite" "${PBDIR}/${PBDB}"	
	
	# make space for new logs
	mkdir -p ${PBDIR}/seiscomp3/log
	ls ${PBDIR}/seiscomp3/* &>/dev/null && rm -r ${PBDIR}/seiscomp3/*
	ls  ${CONFIGDIR}/.logbu &>/dev/null &&    mv   ${CONFIGDIR}/log/* ${CONFIGDIR}/.logbu/
	ls  ${CONFIGDIR}/.logbu &>/dev/null ||    mv   ${CONFIGDIR}/log   ${CONFIGDIR}/.logbu
	
	# make sure seedlink will work, with fifo
	${SEISCOMP_ROOT}/bin/seiscomp enable seedlink
	sed -i 's;plugins\.mseedfifo\.fifo.*;plugins.mseedfifo.fifo = '${SEISCOMP_ROOT}'/var/run/seedlink/mseedfifo;' ${CONFIGDIR}/global.cfg
	grep "plugins.mseedfifo.fifo" ${CONFIGDIR}/global.cfg

	# run the playback
	if [ -z "$EVENTID" ] && [ -z "$FILEIN" ]
	then	
		# continuous data 
		MSFILE=`ls "${PBDIR}"/*sorted-mseed`
        	EVNTFILE=`ls "${PBDIR}"/*_events.xml`
		"$RUNPLAYBACK"  "${PBDIR}/${PBDB}" "${MSFILE}" "${DELAYS}" -c "${CONFIGDIR}" -m ${MODE} -e "${EVNTFILE}"
	else 
		for TMPID in ${evids[@]}
		do
			# event data
			EVTNAME=${TMPID##*/}
			MSFILE=`ls "${PBDIR}/"*${EVTNAME}*.sorted-mseed`
			EVNTFILE=`ls "${PBDIR}/"*${EVTNAME}*.xml`
			"$RUNPLAYBACK"  "${PBDIR}/${PBDB}" "${MSFILE}" "${DELAYS}" -c "${CONFIGDIR}" -m ${MODE} -e "${EVNTFILE}"
		done
	
	fi
	
	# export the results
	mkdir -p ${PBDIR}/xmldump
	rm ${PBDIR}/xmldump/*.xml
	scevtls --plugins dbsqlite3 -d "sqlite3://${PBDIR}/${PBDB}" |while read E 
	do 
		scxmldump --plugins dbsqlite3 -d "sqlite3://${PBDIR}/${PBDB}" -fPAMF -E $E -o ${PBDIR}/xmldump/${E//\//_}.xml 
	done

	# save the logs
	rsync -avzl ${CONFIGDIR}/  ${PBDIR}/seiscomp3/ --exclude="*logbu*"
	ls  ${CONFIGDIR}/log/* &>/dev/null && rm -r ${CONFIGDIR}/log
	ls ${CONFIGDIR}/.logbu &>/dev/null && mv ${CONFIGDIR}/.logbu  ${CONFIGDIR}/log
	
	# print next step
	echo "Examine results with:"
	echo "scolv --offline --debug --plugins dbsqlite3 -d \"sqlite3://${PBDIR}/${PBDB}\" -I \"$MSFILE\"" 	
fi
