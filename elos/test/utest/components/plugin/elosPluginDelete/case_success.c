// SPDX-License-Identifier: MIT

#include "elosPluginDelete_utest.h"

int elosTestElosPluginDeleteSuccessSetup(void **state) {
    elosUnitTestState_t *test = *(elosUnitTestState_t **)state;
    char const *path = "/test/123";
    samconfConfig_t config = {0};
    safuResultE_t result;
    elosPluginId_t id = 42;

    elosPluginParam_t param = {
        .config = &config,
        .data = NULL,
        .id = id,
        .path = path,
    };

    result = elosPluginNew(&test->plugin, &param);
    assert_int_equal(result, SAFU_RESULT_OK);

    return 0;
}

int elosTestElosPluginDeleteSuccessTeardown(UNUSED void **state) {
    return 0;
}

void elosTestElosPluginDeleteSuccess(void **state) {
    elosUnitTestState_t *test = *(elosUnitTestState_t **)state;
    safuResultE_t result;

    TEST("elosPluginDelete");
    SHOULD("%s", "test correct behaviour");

    result = elosPluginDelete(&test->plugin);
    assert_int_equal(result, SAFU_RESULT_OK);
    assert_ptr_equal(test->plugin, NULL);
}
