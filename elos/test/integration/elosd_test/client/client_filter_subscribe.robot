# SPDX-License-Identifier: MIT
*** Settings ***
Documentation     A test suite to check if subscribed client
...               with invalid filer string does not change eolsd behaviour.

Library           String
Library           SSHLibrary
Resource         ../../keywords.resource
Suite Setup       Connect To Target And Log In
Suite Teardown    Close All Connections

*** Variables ***
${INVALID_CLIENT_LOG}    /tmp/elos_client_invalid.log
${VALID_CLIENT_LOG}    /tmp/elos_client_valid.log
@{INVALID_FILTER}    " "
...                  "dsp9imjrewwnufxp98jrewuuuuuuwrevgf"
...                  ".event.Source.appName 'hugo' STRCMP"
...                  ".event.Source.appName 'hugo' EQ"
...                  ".event.Source.appName 'hugo' LT"
...                  ".event.Source.appName hugo STRCMP"
...                  ".event.definitely.not.existing.field 'hugo' STRCMP"
@{MESSAGES}         {"messageCode": 4,"payload":"testEventFiltering"}
...                 {"messageCode": 40,"payload":"testEventFiltering"}
...                 {"messageCode": 400,"payload":"testEventFiltering"}
${VALID_FILTER}    ".event.messageCode 400 EQ"
@{PUBLISH_LOG}
${EVENT}            testEventFiltering
${EVENT_FAILED}     event subscription failed

*** Test Cases ***
Event Not Logged By Client With Invalid Filter
    [Documentation]    A published event is not logged by a client
    ...                with invalid filter string
    [Teardown]         Run Keyword    Remove Temporary Test Files

    FOR    ${filter}    IN    @{INVALID_FILTER}
        Given A Client Filter Is Invalid    ${filter}
        When An Event Is Published
        Then Client Does Not Log It
    END

Client With Invalid Filter Does Not Affect Other Clients
    [Documentation]    A client with invalid filter does not affect other clients
    [Teardown]         Run Keyword    Remove Temporary Test Files

    Given A Client Filter Is Invalid    ${INVALID_FILTER}[1]
    AND A Client Filter Is Valid
    When An Event Is Published
    Then Client With Valid Filter Logs It

*** Keywords ***
A Client Filter Is Invalid
    [Arguments]    ${invalid_filter}
    [Documentation]    Start elos client with an invalid filter string

    ${output}=    Execute Command    elosc -s ${invalid_filter} > ${INVALID_CLIENT_LOG} 2>&1 &
    Log    client with filter ${invalid_filter} started

A Client Filter Is Valid
    [Documentation]    Start elos client with a valid filter string

    ${output}=    Execute Command    elosc -s ${VALID_FILTER} > ${VALID_CLIENT_LOG} 2>&1 &

    Log    client with filter ${VALID_FILTER} started

An Event Is Published
    [Documentation]    Publish Created Messages

    FOR    ${message}    IN    @{MESSAGES}
        ${publish_output}=    Execute Command    elosc -p '${message}'
        Append To List    ${PUBLISH_LOG}     ${publish_output}
    END
    Log List    ${PUBLISH_LOG}
    Sleep    1s

Client Does Not Log It
    [Documentation]    Client with invalid filter will not be able to log event

    ${output}=    Execute Command    cat ${INVALID_CLIENT_LOG}
    Log    ${output}
    Should Contain   ${output}    ${EVENT_FAILED}

Client With Valid Filter Logs It
    [Documentation]    Client with valid filter will be able to log event
    Run Keyword        Terminate Running Client Instances

    ${received}=    Set Variable    0
    WHILE    ${received} == 0          limit=5 seconds
        ${output}=    Execute Command    cat ${VALID_CLIENT_LOG}
        ${ret}=    Get Lines Containing String    ${output}    ${EVENT}
        ${received}=    Get Length    ${ret}
    END
    Log    ${output}
    Should Contain   ${output}    ${EVENT}

Terminate Running Client Instances
    [Documentation]    Terminate all running client instance after
    ...                each test case run
    ${output}    ${rc}=    Execute Command     pkill elosc    return_rc=True
    Should Be Equal As Integers    ${rc}    0

Remove Temporary Test Files
    [Documentation]    Remove all test related temp files

    ${output}    ${rc}=    Execute Command     rm -rf ${INVALID_CLIENT_LOG} ${VALID_CLIENT_LOG}    return_rc=True
    Should Be Equal As Integers    ${rc}    0
