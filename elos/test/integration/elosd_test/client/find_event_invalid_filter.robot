# SPDX-License-Identifier: MIT
*** Settings ***
Documentation     A test suite to check if client with invalid filter
...               is not able to retrieve published messages

Library           String
Library           SSHLibrary
Resource         ../../keywords.resource
Suite Setup       Connect To Target And Log In
Suite Teardown    Close All Connections

*** Variables ***
@{MESSAGES}         {"messageCode": 4,"payload":"testEventFiltering"}
...                 {"messageCode": 40,"payload":"testEventFiltering"}
...                 {"messageCode": 400,"payload":"testEventFiltering"}
${SEARCH_STRING}    "log event find failed"
@{PUBLISH_LOG}

*** Test Cases ***
Published Events Are Not Retrieved By Client With Invalid Filter
    [Documentation]    Published message can not be retrieved using an invalid
    ...                filter string. Client with invalid filter does not
    ...                influence elosd.
    [Template]         Invalid Filter Test

    " "
    "dsp9imjrewwnufxp98jrewuuuuuuwrevgf"
    ".event.Source.appName 'hugo' STRCMP"
    ".event.source.appName 'hugo' EQ"
    ".event.source.appName 'hugo' LT"
    ".event.Source.appName hugo STRCMP"
    ".event.definitely.not.existing.field 'hugo' STRCMP"

*** Keywords ***
Invalid Filter Test
    [Documentation]    test template to check different types of invalid filters.
    [Arguments]        ${filter}

    When An Event Is Published
    Then Client Fails To Retrieve Event With    ${filter}
    And Elosd Is Running

An Event Is Published
    [Documentation]    Publish Created Messages

    FOR    ${message}    IN    @{MESSAGES}
        ${publish_output}=    Execute Command    elosc -p '${message}'
        Append To List    ${PUBLISH_LOG}     ${publish_output}
    END
    Log List    ${PUBLISH_LOG}
    Sleep    1s

Client Fails To Retrieve Event With
    [Arguments]        ${filter}
    [Documentation]    Client with invalid filter string does not retrieve published messages

    ${output}    ${rc}=    Execute Command    elosc -f ${filter} 2>&1 | grep ${SEARCH_STRING}    return_rc=True
    Should Be Equal As Integers    ${rc}    0
    Should Not Be Empty    ${output}

Elosd Is Running
    [Documentation]    Elosd is still running

    ${output}=    Execute Command    pgrep elosd
    Should Not Be Empty    ${output}
