#!/bin/sh

CMDPATH=$(realpath $(dirname $0))
BASE_DIR=$CMDPATH/../..
BUILD_TYPE="${BUILD_TYPE-Debug}"

export TEST_SOURCE_DIR="$BASE_DIR/test/smoketest"
export BUILD_DIR="$BASE_DIR/build/$BUILD_TYPE/"
export DIST_DIR="${BUILD_DIR}/dist"
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH-""}:${DIST_DIR}/usr/local/lib"
export PATH="${PATH}:${DIST_DIR}/usr/local/bin"
export NETSTAT=$(which netstat 2>/dev/null || which ss 2> /dev/null || echo "no ${NETSTAT} compliant tool found")
export SMOKETEST_DIR=${SMOKETEST_DIR-$TEST_SOURCE_DIR}
export SMOKETEST_RESULT_DIR=${SMOKETEST_RESULT_DIR-"$BUILD_DIR/result/smoketest_results"}
export SMOKETEST_TMP_DIR="${SMOKETEST_TMP_DIR-"/tmp/elosd"}"

export ELOS_SYSLOG_PATH=${ELOS_SYSLOG_PATH-"${SMOKETEST_TMP_DIR}/elosd.syslog.socket"}
export ELOS_KMSG_FILE=${ELOS_KMSG_FILE-"${SMOKETEST_TMP_DIR}/elosd.kmsg"}
export ELOS_SCANNER_PATH=${ELOS_SCANNER_PATH-"$DIST_DIR/usr/local/lib/elos/scanner"}
export ELOS_BACKEND_PATH=${ELOS_BACKEND_PATH-"$DIST_DIR/usr/local/lib/elos/backend"}
export ELOS_LOG_LEVEL=DEBUG

export ELOS_CONFIG_PATH=${ELOS_CONFIG_PATH-"$SMOKETEST_DIR/config.json"}

prepare_env() {
    test_name=${1?:"first parameter missing"}

    result_dir="$SMOKETEST_RESULT_DIR/${test_name}"
    if [ -e $result_dir ]
    then
        rm -rf $result_dir
    fi
    mkdir -p $result_dir

    if [ -e "$SMOKETEST_TMP_DIR" ]
    then
        rm -rf $SMOKETEST_TMP_DIR
    fi
    mkdir -p $SMOKETEST_TMP_DIR

    export RESULT_DIR=$result_dir

    . $CMDPATH/smoketest_log.sh
    setup_log

    ELOSD_PIDS=$(pgrep elosd || echo "")
    for ELOSD_PID in $ELOSD_PIDS; do
       find /proc/$$ -type d -name $ELOSD_PID >/dev/null 2>&1
       if [ $? -ne 0 ]; then
           log "Found elosd from other process".
           continue
       fi
       log "Existing instance of elosd found ($ELOSD_PID), terminating..."
       kill -15 $ELOSD_PID
       wait $ELOSD_PID > /dev/null
       log "done ($?)"
       sleep 2s
    done

    export ELOS_STORAGE_BACKEND_JSONBACKEND_FILE="${result_dir}/elosd_event_%count%.log"
}

wait_for_file() {
    local i=0
    while [ ! -e $1 ]
    do
      i=$((i+1))
      sleep 0.1s
      if [ $i -gt 100 ]; then
         log "Error: Waiting for file $1 timed out"
         exit 124
      fi
    done

}

wait_for_elosd_socket() {
    local i=0
    ${NETSTAT} -l | grep 54321 | grep tcp 2>&1 > /dev/null
    while [ $? -ne 0 ]
    do
      i=$((i+1))
      sleep 0.1s
      if [ $i -gt 100 ]; then
         log "Error: Waiting for elosd socket timed out"
         exit 124
      fi
      ${NETSTAT} -l | grep 54321 | grep tcp 2>&1 > /dev/null
    done
}

smoketest_elosd() {
    prepare_env "elosd"

    log "Starting Elosd"
    elosd > $RESULT_DIR/elosd.txt 2>&1 &
    ELOSD_PID=$!
    log "Elosd has PID ${ELOSD_PID}"
    wait_for_elosd_socket
    find /proc -maxdepth 1 -name $ELOSD_PID -exec kill -15 $ELOSD_PID \; &&
    wait $ELOSD_PID || true
    log "Killed Elosd"

    STRINGS="listen on: ${ELOSD_INTERFACE-"0.0.0.0"}:${ELOSD_PORT-"54321"}
hardwareid: $(cat /etc/machine-id)
log level: ${ELOS_LOG_LEVEL}
log filter: ${ELOS_LOG_FILTER-""}
scanner path: ${ELOS_SCANNER_PATH-"(null)"}
Running...
Shutting down..."
    echo "${STRINGS}" >> ${SMOKETEST_TMP_DIR}/expected_elosd_logs.txt

    local FAIL=0
    while IFS= read -r str; do

        log "look for '$str'"
        grep "$str" $RESULT_DIR/elosd.txt > /dev/null 2>&1
        case $? in
            0)
                log "Found: '$str'"
            ;;
            1)
                log_err "Not found: '$str'"
                FAIL=$((FAIL+1))
            ;;
            *)
                log_err "Failed to check result, cancel test"
                FAIL=$((FAIL+1))
                break
            ;;
        esac
    done < ${SMOKETEST_TMP_DIR}/expected_elosd_logs.txt

    return $FAIL
}

smoketest_elosd_config_not_found() {
    prepare_env "elosd_config_not_found"

    REAL_ELOS_CONFIG_PATH=$ELOS_CONFIG_PATH
    ELOS_CONFIG_PATH=/dev

    log "Starting Elosd"
    elosd > $RESULT_DIR/elosd_config_not_set.txt 2>&1 &
    ELOSD_PID=$!
    log "Elosd has PID ${ELOSD_PID}"
    sleep 1s
    find /proc -maxdepth 1 -name $ELOSD_PID -exec kill -15 $ELOSD_PID \; &&
    wait $ELOSD_PID || true
    log "Killed Elosd"

    FAIL=0
    str="ERROR: Failed to lookup backend for /dev."
    grep -q "$str" $RESULT_DIR/elosd_config_not_set.txt

    if [ $? -ne 0 ]; then
        log_err "$str"
        FAIL=1
    fi

    export ELOS_CONFIG_PATH=${REAL_ELOS_CONFIG_PATH-"$SMOKETEST_DIR/config.json"}
    return $FAIL
}

smoketest_client() {
    prepare_env "client"

    log "Starting Client Demo"
    demo_libelos_v2 > $RESULT_DIR/client_output.txt 2>&1

    sed -i -e 's/[0-9]\+\([.,]\)/xyz\1/g' $RESULT_DIR/client_output.txt

    output_diff=$(diff $RESULT_DIR/client_output.txt $SMOKETEST_DIR/client_output.txt || echo "diff returned: $?")
    if [ -n "$output_diff" ]
    then
        log_err "Problems occured while comparing the client output:"
        log_err "$output_diff"
        return 1
    fi

    return 0
}

smoketest_coredump() {
    prepare_env "elos-coredump"

    RESULT=0

    log "Starting elosd"
    elosd > $RESULT_DIR/elosd.log 2>&1 &
    ELOSD_PID=$!

    wait_for_elosd_socket

    log "Starting elos coredump test"

    log "Triggering coredump"
    TEST_MESSAGE="THIS IS THE DUMP"
    echo $TEST_MESSAGE | elos-coredump 1 /usr/bin/example 2 3 11 333333 exampletest > $RESULT_DIR/coredump_trigger.log 2>&1

    elosc -f ".event.messageCode 5005 EQ" > $RESULT_DIR/coredump_event.log 2>&1

    if grep -q "\"messageCode\":5005" $RESULT_DIR/coredump_event.log
    then
        log "Success coredump event logged"
    else
        log_err "coredump event not logged"
        RESULT=1
    fi

    log "Stop elosd ($ELOSD_PID) ..."
    kill $ELOSD_PID > /dev/null
    wait $ELOSD_PID > /dev/null
    log "done"

    return $RESULT
}

smoketest_syslog() {
    prepare_env "syslog"

    TEST_MESSAGE="an arbitrary syslog message"

    log "Starting elosd"
    elosd > $RESULT_DIR/elosd.log 2>&1 &
    ELOSD_PID=$!

    wait_for_elosd_socket
    wait_for_file $ELOS_SYSLOG_PATH

    log "Starting syslog test"
    syslog_example "$TEST_MESSAGE" > $RESULT_DIR/syslog_example.log 2>&1 &
    SYSLOG_EXAMPLE_PID=$!

    log "wait for syslog_example to finish ..."
    wait $SYSLOG_EXAMPLE_PID
    log "done"

    log "Stop elosd ($ELOSD_PID) ..."
    kill $ELOSD_PID > /dev/null
    wait $ELOSD_PID > /dev/null
    log "done"

    TEST_RESULT=0
    grep "\[receive message\] " $RESULT_DIR/syslog_example.log | grep -q "$TEST_MESSAGE"
    if [ $? -ne 0 ]; then
        log_err "missing message: '$TEST_MESSAGE'"
        TEST_RESULT=1
    fi

    return $TEST_RESULT
}

smoketest_kmsg() {
    prepare_env "kmsg"

    LOG_ELOSD="$RESULT_DIR/elosd.log"
    LOG_ELOSCL="$RESULT_DIR/elosc_poll.log"
    LOG_KMSG="$RESULT_DIR/kmsg_example.log"
    TEST_MESSAGE="12,1234,12345678901,-;smoketest: kernel message"
    FILTERSTRING=".event.source.fileName '${ELOS_KMSG_FILE}' STRCMP"

    log "Starting elosd"
    elosd > $LOG_ELOSD 2>&1 &
    ELOSD_PID=$!

    wait_for_elosd_socket
    wait_for_file $ELOS_KMSG_FILE

    log "Polling KMSG"
    elosc -s "$FILTERSTRING" > $LOG_ELOSCL 2>&1 &
    POLL_CLIENT_PID=$!
    sleep 1s

    log "Writing kernel message"
    echo $TEST_MESSAGE > $ELOS_KMSG_FILE 2> $LOG_KMSG
    sleep 1s

    log "Stop elosd ($ELOSD_PID)"
    kill $ELOSD_PID > /dev/null
    wait $ELOSD_PID > /dev/null

    log "Stop elosc ($POLL_CLIENT_PID)"
    kill $POLL_CLIENT_PID > /dev/null
    wait $POLL_CLIENT_PID > /dev/null

    TEST_RESULT=0
    grep "smoketest" $LOG_ELOSCL | grep -q "$TEST_MESSAGE"
    if [ $? -ne 0 ]; then
        log_err "missing message: '$TEST_MESSAGE'"
        TEST_RESULT=1
    fi

    return $TEST_RESULT
}

check_for_attribute() {
    local KEY=$1
    local VALUE=$2

    grep "\"$KEY\":$VALUE" $RESULT_DIR/elosc_poll_1.log > /dev/null &
    grep "\"$KEY\":$VALUE" $RESULT_DIR/elosc_poll_2.log > /dev/null
    if [ $? -ne 0 ]; then
        log_err "missing '$KEY': '$VALUE'"
        return 1
    fi
    return 0
}

smoketest_publish_poll() {
    prepare_env "publish_poll"

    local ELOSC_FILE_NAME=$(which elosc)
    local FILTERSTRING=".event.source.appName 'publish_poll' STRCMP"
    local MESSAGE_TEMPLATE="
{
  \"date\": [%s],
  \"source\": {
    \"appName\": \"publish_poll\",
    \"fileName\": \"$ELOSC_FILE_NAME\",
    \"pid\": 42
  },
  \"severity\": %d,
  \"hardwareid\": \"$HOSTNAME\",
  \"classification\": $(printf %u 0x0000BEEFCAFFEE00),
  \"messageCode\": %d,
  \"payload\": \"test message %d\"
}"

    log "Starting elosd"
    elosd > $RESULT_DIR/elosd.log 2>&1 &
    ELOSD_PID=$!

    sleep 0.5s

    log "Polling client 1 ..."
    elosc -s "$FILTERSTRING" > $RESULT_DIR/elosc_poll_1.log 2>&1 &
    POLL_CLIENT_1_PID=$!

    log "Polling client 2 ..."
    elosc -s "$FILTERSTRING" > $RESULT_DIR/elosc_poll_2.log 2>&1 &
    POLL_CLIENT_2_PID=$!

    sleep 0.5s

    for i in `seq 1 10`; do
        local MESSAGE=$(printf "$MESSAGE_TEMPLATE" `date "+%s,0"` $i $i $i )
        log "Publish \"$MESSAGE\""
        elosc -p "$MESSAGE" >> $RESULT_DIR/elosc_publish.log 2>&1
    done

    sleep 1s
    kill $POLL_CLIENT_1_PID $POLL_CLIENT_2_PID $ELOSD_PID >/dev/null
    wait $POLL_CLIENT_1_PID $POLL_CLIENT_2_PID $ELOSD_PID > /dev/null
    log "done ($?)"

    local TEST_RESULT=0
    local ELOSC_FILE_NAME_ESCAPED=$(echo $ELOSC_FILE_NAME | sed 's@/@\\\\\/@g')
    for i in `seq 1 10`; do
        check_for_attribute "payload" "\"test message $i\"" \
        && check_for_attribute "messageCode" "$i" \
        && check_for_attribute "date" "" \
        && check_for_attribute "appName" "\"publish_poll\"" \
        && check_for_attribute "pid" "42" \
        && check_for_attribute "severity" "$i" \
        && check_for_attribute "hardwareid" "\"$HOSTNAME\"" \
        && check_for_attribute "classification" "$(printf %u 0x0000BEEFCAFFEE00)" \
        && check_for_attribute "fileName" "\"${ELOSC_FILE_NAME_ESCAPED}\"" \
        || TEST_RESULT=1
    done

    return $TEST_RESULT
}

smoketest_locale() {
    prepare_env "locale"

    local VALID_JSON_MESSAGE="{\"severity\":1,\"hardwareid\":\"localhost\",\"classification\":42.5,\
\"messageCode\":32,\"payload\":\"this_is_payload\"}"

    local INVALID_JSON_MESSAGE="{\"date\":[%s],\"source\":{\"appName\":\"☃\",\
\"fileName\":\"𝔾𝓻ÿ𝓣𝔃ë𝐋𝐵𝓲𝓂𝓕\",\"pid\":42},\"severity\":💀💀💀,\"hardwareid\":\"🙊\",\
\"classification\":\"🙉\",\"messageCode\":\"🙈\",\"payload\":\"♔♕♖♗♘♙♚♛♜♝♞♟\"}"

    #start elos and client

    log "Starting elosd"
    elosd > $RESULT_DIR/elosd.log 2>&1 &
    ELOSD_PID=$!

    sleep 0.5s

    log "Start listening client"
    elosc -s "1 1 EQ" -r 100 >> $RESULT_DIR/event.log 2>&1 &
    CLIENT_PID=$!

    sleep 0.5s

    #send valid messages
    tinyElosc -v >> $RESULT_DIR/event.log 2>&1
    tinyElosc -s ".event.payload 'Ϡ𝔾𝓻ÿ𝓣𝔃ë𝐋Ϡ' STRCMP" >> $RESULT_DIR/event.log 2>&1
    tinyElosc -p "{\"payload\":\"this is payload\"}" >> $RESULT_DIR/event.log 2>&1
    tinyElosc -p "{\"payload\":\"Ϡ𝔾𝓻ÿ𝓣𝔃ë𝐋Ϡ\"}" >> $RESULT_DIR/event.log 2>&1
    tinyElosc -p $VALID_JSON_MESSAGE >> $RESULT_DIR/event.log 2>&1

    #send invalid messages
    tinyElosc -s "\"Ϡ𝔾𝓻ÿ𝓣𝔃ë𝐋Ϡ\"" >> $RESULT_DIR/event.log 2>&1
    tinyElosc -p "Ϡ𝔾𝓻ÿ𝓣𝔃ë𝐋Ϡ" >> $RESULT_DIR/event.log 2>&1
    tinyElosc -p "{\"Ϡ𝔾𝓻ÿ𝓣𝔃ë𝐋Ϡ\"}" >> $RESULT_DIR/event.log 2>&1
    tinyElosc -p "{\"invalid\":Ϡ𝔾𝓻ÿ𝓣𝔃ë𝐋Ϡ}" >> $RESULT_DIR/event.log 2>&1
    tinyElosc -p $INVALID_JSON_MESSAGE >> $RESULT_DIR/event.log 2>&1

    #send empty messages
    tinyElosc -s "" >> $RESULT_DIR/event.log 2>&1 #invalid
    tinyElosc -p "" >> $RESULT_DIR/event.log 2>&1 #invalid

    #check if elosd is still alive
    local alive=0
    local success=1
    log $(ps -p ${ELOSD_PID})
    if [ $? -eq 0 ]
    then
        alive=$((alive+1))
        success=$((success+1))
    fi

    #restart elosd and client with different locale
    kill $CLIENT_PID $ELOSD_PID >/dev/null
    wait $CLIENT_PID $ELOSD_PID > /dev/null

    log "Change locale to DE"
    export LC_ALL=de_DE.utf8

    log "Restart elosd and client"
    elosd > $RESULT_DIR/elosd.log 2>&1 &
    ELOSD_PID=$!
    sleep 0.5s
    elosc -s "1 1 EQ" -r 100 >> $RESULT_DIR/event.log 2>&1 &
    CLIENT_PID=$!
    sleep 0.5s

    #locale tests
    tinyElosc -p "{\"classification\":42,5}" >> $RESULT_DIR/event.log 2>&1 #invalid
    tinyElosc -p "{\"payload\":\"42,5\"}" >> $RESULT_DIR/event.log 2>&1 #valid
    tinyElosc -p "{\"payload\":\"$(date)\"}" >> $RESULT_DIR/event.log 2>&1 #valid
    sleep 0.1s

    #check test success
    log $(ps -p ${ELOSD_PID})
    if [ $? -eq 0 ]
    then
        alive=$((alive+1))
        success=$((success+1))
    fi

    kill $CLIENT_PID >/dev/null
    wait $CLIENT_PID > /dev/null
    kill $ELOSD_PID >/dev/null
    wait $ELOSD_PID > /dev/null

    sync $RESULT_DIR

    local versionResponses=$(cat $RESULT_DIR/event.log | grep -wc "\"version\":")
    log "found $versionResponses valid version messages and expected 1"
    if [ $versionResponses -eq 1 ]; then
        success=$((success+1))
    fi
    local nonErrors=$(cat $RESULT_DIR/event.log | grep -wc "\"error\":null")
    #note: "tinyElosc -s" always sends an additional valid eventCreate that is counted too
    log "found $nonErrors valid messages and expected 7"
    if [ $nonErrors -eq 7 ]; then
        success=$((success+1))
    fi

    local errors1=$(cat $RESULT_DIR/event.log | grep -wc error)
    local errors2=$(cat $RESULT_DIR/event.log | grep -wc ERR)
    local errorCount=$((errors1 + errors2 - nonErrors))
    log "found $errorCount errors and expected 8"
    if [ $errorCount -eq 8 ]; then
        success=$((success+1))
    fi

    if [ $alive -eq 2 ]; then
        log "elosd kept running after all invalid messages"
    else
        log "elosd was killed by the messages: $alive"
    fi

    if [ $success -eq 6 ]; then
        return 0
    else
        return $((6-success))
    fi
}

smoketest_find_event() {
    prepare_env "find_event"
    set +e

    local LOG_ELOSD="$RESULT_DIR/elosd.log"
    local LOG_ELOSC_PUBLISH="$RESULT_DIR/elosc_publish.log"
    local LOG_ELOSC_SUBSCRIBE="$RESULT_DIR/elosc_subscribe.log"
    local LOG_ELOSC_UNSUBSCRIBE="$RESULT_DIR/elosc_unsubscribe.log"
    local LOG_ELOSC_FINDEVENT="$RESULT_DIR/elosc_findevent.log"

    local MESSAGE01="{\"messageCode\":4,\"payload\":\"testEventFiltering\"}"
    local MESSAGE02="{\"messageCode\":40,\"payload\":\"testEventFiltering\"}"
    local MESSAGE03="{\"messageCode\":400,\"payload\":\"testEventFiltering\"}"
    local FILTERSTRING=".event.messageCode 400 EQ"

    local ELOSD_PID
    local ELOSD_ALIVE=0
    local ELOSC_FINDEVENT_MATCHES=0
    local ELOSC_SUBSCRIBE_PID

    # Setup environment
    log "Start elosd..."
    ELOS_STORAGE_BACKEND_JSONBACKEND_FILE="$RESULT_DIR/elosd_event_%count%.log" elosd > $LOG_ELOSD 2>&1 &
    ELOSD_PID=$!
    sleep 0.5s

    log "Start subscriber client ..."
    elosc -s "$FILTERSTRING" -r 100 > $LOG_ELOSC_SUBSCRIBE 2>&1 &
    ELOSC_SUBSCRIBE_PID=$!
    sleep 0.5s

    # Fetch the corresponding queue id
    EVENT_QUEUE_ID=$(sed -n "s/successfully subscribed to event queue \([0-9]\+\)/\1/p" "$LOG_ELOSC_SUBSCRIBE")
    log "Got event queue id $EVENT_QUEUE_ID"

    # Publish messages
    elosc -p "$MESSAGE01" > $LOG_ELOSC_PUBLISH 2>&1
    elosc -p "$MESSAGE02" >> $LOG_ELOSC_PUBLISH 2>&1
    elosc -p "$MESSAGE03" >> $LOG_ELOSC_PUBLISH 2>&1
    sleep 0.5s

    # Search in the log for specific messages
    log "Ask elosd to find matching events..."
    elosc -f "$FILTERSTRING" > $LOG_ELOSC_FINDEVENT 2>&1

    # Check success conditions
    ELOSC_FINDEVENT_MATCHES=$(grep -wc testEventFiltering $LOG_ELOSC_FINDEVENT)
    log $(ps -p ${ELOSD_PID})
    if [ $? -eq 0 ]
    then
        ELOSD_ALIVE=1
    fi

    # Unsubscribe from event queues
    elosc -u "$EVENT_QUEUE_ID" > $LOG_ELOSC_UNSUBSCRIBE 2>&1

    #teardown
    kill -TERM $ELOSC_SUBSCRIBE_PID $ELOSD_PID
    wait $ELOSC_SUBSCRIBE_PID $ELOSD_PID > /dev/null 2>&1

    if [ "$ELOSD_ALIVE" = "1" ] && [ "$ELOSC_FINDEVENT_MATCHES" = "1" ]
    then
        log "TEST SUCCESS"
        return 0
    elif [ "$ELOSD_ALIVE" != "1" ]
    then
        log "TEST FAILED since elosd stopped working"
        return 1
    else
        log "TEST FAILED with $ELOSC_FINDEVENT_MATCHES matching events while 1 was expected"
        return 2
    fi
}

smoketest_backend_dummy() {
    prepare_env "backend_dummy"

    LOG_ELOSD="$RESULT_DIR/elosd.log"
    TEST_RESULT=0

    log "Starting elosd"
    elosd > "$LOG_ELOSD" 2>&1 &
    ELOSD_PID=$!
    sleep 1s

    log "Stop elosd ($ELOSD_PID)"
    kill $ELOSD_PID > /dev/null
    wait $ELOSD_PID > /dev/null

    TEST_MATCH='/Plugin\s.Dummy/!d; /loaded/p; /started/p; /Unloading/p;'
    TEST_COUNT=$(sed -n -e "$TEST_MATCH" "$LOG_ELOSD" | wc -l)
    if [ "$TEST_COUNT" != "3" ]; then
        log_err "Missing messages for Plugin 'Dummy' ($TEST_COUNT of 3 lines found)"
        TEST_RESULT=1
    fi

    TEST_MATCH='/Plugin\s.SecondDummy/!d; /loaded/p; /started/p; /Unloading/p;'
    TEST_COUNT=$(sed -n -e "$TEST_MATCH" "$LOG_ELOSD" | wc -l)
    if [ "$TEST_COUNT" != "3" ]; then
        log_err "Missing messages for Plugin 'SecondDummy' ($TEST_COUNT of 3 lines found)"
        TEST_RESULT=1
    fi

    return $TEST_RESULT
}

smoketest_dual_json_plugin() {
    prepare_env "dual_json_plugin"

    local LOG_ELOSD="$RESULT_DIR/elosd.log"

    export ELOS_CONFIG_PATH=$SMOKETEST_DIR/config_dual.json
    export ELOS_STORAGE_BACKEND_COREDUMP_FILE=$RESULT_DIR/elos_coredump_%count%.log
    COREDUMP_FILE=$RESULT_DIR/elos_coredump_0.log
    export ELOS_STORAGE_BACKEND_JSONBACKEND_FILE=$RESULT_DIR/elos_jsonbackend_%count%.log
    JSONBACKEND_FILE=$RESULT_DIR/elos_jsonbackend_0.log
    TEST_RESULT=0

    log "Starting elosd"
    elosd > "$LOG_ELOSD" 2>&1 &
    ELOSD_PID=$!

    wait_for_elosd_socket
    wait_for_file $COREDUMP_FILE
    wait_for_file $JSONBACKEND_FILE

    elosc -p "{\"payload\":\"coredump\", \"messageCode\":5005}" >> $RESULT_DIR/event.log 2>&1
    elosc -p "{\"payload\":\"not coredump\", \"messageCode\":5004}" >> $RESULT_DIR/event.log 2>&1

    log "Stop elosd ($ELOSD_PID)"
    kill $ELOSD_PID > /dev/null
    wait $ELOSD_PID > /dev/null

    coredump_number=$(wc -l $COREDUMP_FILE | sed "s# $COREDUMP_FILE##g" )
    if [ "$coredump_number" != "1" ]; then
        log_err "unexpected amount of coredumps: $coredump_number"
        TEST_RESULT=1
    fi

    jsonbackend_number=$(wc -l $JSONBACKEND_FILE | sed "s# $JSONBACKEND_FILE##g" )
    if [ "$jsonbackend_number" != "1" ]; then
        log_err "unexpected amount of regular logs: $jsonbackend_number"
        TEST_RESULT=1
    fi

    return $TEST_RESULT
}



# $1 - test name
# $2 - (optional) test function - valid options are [test_expect_success|test_expect_failure|test_expect_unstable]
call_test() {
    test_name=$1
    test_method=${2-"test_expect_success"}

    local result=1
    local skipped="false"

    echo -n "${test_name} ... "

    if [ "$ENABLED_TESTS" = "" ]; then
        echo $DISABLED_TESTS | grep -q "$test_name\b"
        if [ $? -ne 0 ]; then
            smoketest_${test_name}
            result=$?
        else
            skipped="true"
        fi
    else
        echo $ENABLED_TESTS | grep -q  "$test_name\b"
        if [ $? -eq 0 ]; then
                smoketest_${test_name}
                result=$?
        else
            skipped="true"
        fi
    fi

    if [ "${skipped}" = "true" ]; then
        echo "SKIPPED"
	result=0
    else
        if [ ${result} -eq 0 ]; then
            echo "OK"
        else
            echo "FAILED"
        fi
    fi

    return ${result}
}

FAILED_TESTS=0
call_test "elosd" || FAILED_TESTS=$((FAILED_TESTS+1))
call_test "elosd_config_not_found" || FAILED_TESTS=$((FAILED_TESTS+1))
call_test "client" || FAILED_TESTS=$((FAILED_TESTS+1))
call_test "syslog" || FAILED_TESTS=$((FAILED_TESTS+1))
call_test "coredump" || FAILED_TESTS=$((FAILED_TESTS+1))
call_test "kmsg" || FAILED_TESTS=$((FAILED_TESTS+1))
call_test "publish_poll" || FAILED_TESTS=$((FAILED_TESTS+1))
call_test "locale" || FAILED_TESTS=$((FAILED_TESTS+1))
call_test "find_event" || FAILED_TESTS=$((FAILED_TESTS+1))
call_test "backend_dummy" || FAILED_TESTS=$((FAILED_TESTS+1))
call_test "dual_json_plugin" || FAILED_TESTS=$((FAILED_TESTS+1))

exit ${FAILED_TESTS}
