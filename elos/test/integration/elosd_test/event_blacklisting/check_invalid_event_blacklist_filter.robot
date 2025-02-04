# SPDX-License-Identifier: MIT
*** Settings ***
Documentation     A test suite to check invalid blacklist filter

Resource          ../../elosd-keywords.resource
Resource          ../../keywords.resource

Library           ../../libraries/TemplateConfig.py

Suite Setup       Connect To Target And Log In
Suite Teardown    Close All Connections

*** Variables ***
${BLACKLIST_FILTER}     .event.messagecode 2010 EQ
@{PROCESS_FILTER}       1 0 EQ                 # all processes are unauthorized

*** Test Cases ***
01_Test_Invalid_Blacklist_Filter
    [Documentation]    Check invalid blacklist filter.
    [Teardown]         Reset Elosd Config

    Given An Invalid Blacklist Filter Is Set
    When Unauthorized Process Tries To Publish A Blacklisted Event
    Then A Security Event Is Published

*** Keywords ***
An Invalid Blacklist Filter Is Set
    [Documentation]    Set an invalid blacklist filter in config

    Stop Elosd
    Wait For Elosd To Stop
    Set Config From Template    EventBlacklist=${BLACKLIST_FILTER}    authorizedProcesses=${PROCESS_FILTER}
    Start Elosd
    Wait Till Elosd Is Started


Unauthorized Process Tries To Publish A Blacklisted Event
    [Documentation]    An elos client tries to publish a black listed event and fails

    ${rc}    Execute And Log    elosc -p '{"messageCode": 2010}'    ${RETURN_RC}
    Executable Returns An Error    ${rc}


A Security Event Is Published
    [Documentation]    Attempt to publish a blacklisted event will lead to a security event
    ...                to be published if client is unauthorized.

    ${stdout}    ${rc}   Execute And Log    elosc -f ".event.messageCode 8007 EQ"    ${RETURN_STDOUT}    ${RETURN_RC}
    Should Contain    ${stdout}    2010
    Executable Returns No Errors    ${rc}    Blacklisted event not filtered out by blacklist filter


Reset Elosd Config
    [Documentation]     reset elosd config to default during test teardown.

    Stop Elosd
    Wait For Elosd To Stop
    Cleanup Template Config
    Start Elosd
    Wait Till Elosd Is Started
