// SPDX-License-Identifier: MIT

#define _GNU_SOURCE

#include <safu/mutex.h>
#include <sys/eventfd.h>
#include <sys/time.h>

#include "clientmanager_private.h"
#include "elos/clientmanager/clientauthorization.h"
#include "elos/clientmanager/clientconnection.h"
#include "elos/clientmanager/clientmanager.h"

#define CONNECTION_SEMAPHORE_TIMEOUT_SEC  0
#define CONNECTION_SEMAPHORE_TIMEOUT_NSEC (100 * 1000 * 1000)
#define CONNECTION_PSELECT_TIMEOUT_SEC    0
#define CONNECTION_PSELECT_TIMEOUT_NSEC   (100 * 1000 * 1000)
#define TIMESPEC_1SEC_IN_NSEC             1000000000L

static inline void _calculateTvSeconds(struct timespec *ts) {
    struct timespec connSemTimeOut = {.tv_sec = CONNECTION_SEMAPHORE_TIMEOUT_SEC,
                                      .tv_nsec = CONNECTION_SEMAPHORE_TIMEOUT_NSEC};
    struct timeval tmpTs, tmpTimeOut, tmpResult;
    TIMESPEC_TO_TIMEVAL(&tmpTs, ts);
    TIMESPEC_TO_TIMEVAL(&tmpTimeOut, &connSemTimeOut);

    timeradd(&tmpTs, &tmpTimeOut, &tmpResult);
    TIMEVAL_TO_TIMESPEC(&tmpResult, ts);
}

safuResultE_t elosClientManagerThreadGetFreeConnectionSlot(elosClientManager_t *clientManager, int *slot) {
    sem_t *connectionSemaphore = &clientManager->sharedData.connectionSemaphore;
    struct timespec semTimeOut = {0};
    safuResultE_t result = SAFU_RESULT_OK;

    *slot = -1;

    int retval = clock_gettime(CLOCK_REALTIME, &semTimeOut);
    if (retval < 0) {
        safuLogCritF("clock_gettime failed! - %s", strerror(errno));
        result = SAFU_RESULT_FAILED;
        raise(SIGTERM);
    } else {
        _calculateTvSeconds(&semTimeOut);
        retval = sem_timedwait(connectionSemaphore, &semTimeOut);
        if (retval < 0) {
            if ((errno == ETIMEDOUT) || (errno == EINTR)) {
                safuLogInfoF("sem_timedwait stopped - %s", strerror(errno));
            } else {
                safuLogCritF("sem_timedwait failed! - %s", strerror(errno));
                result = SAFU_RESULT_FAILED;
                raise(SIGTERM);
            }
        } else {
            for (int i = 0; i < ELOS_CLIENTMANAGER_CONNECTION_LIMIT; i += 1) {
                elosClientConnection_t *connection = &clientManager->connection[i];
                bool active = false;

                result = elosClientConnectionIsActive(connection, &active);
                if (result != SAFU_RESULT_OK) {
                    safuLogErrF("elosClientConnectionIsTaken failed for connection slot:%d", i);
                    break;
                } else if (active == false) {
                    *slot = i;
                    break;
                }
            }
        }
    }

    return result;
}

safuResultE_t elosClientManagerThreadWaitForIncomingConnection(elosClientManager_t *clientManager, int slot,
                                                               int *socketFd) {
    elosClientConnection_t *conn = &clientManager->connection[slot];
    struct timespec timeOut = {.tv_sec = CONNECTION_PSELECT_TIMEOUT_SEC, .tv_nsec = CONNECTION_PSELECT_TIMEOUT_NSEC};
    safuResultE_t result = SAFU_RESULT_FAILED;

    for (;;) {
        socklen_t addrLen = sizeof(struct sockaddr_in);
        // struct sockaddr_in addr = {0};
        int retval;
        fd_set readFds;

        FD_ZERO(&readFds);
        FD_SET(clientManager->fd, &readFds);

        if (!(atomic_load(&clientManager->flags) & ELOS_CLIENTMANAGER_LISTEN_ACTIVE)) {
            break;
        }

        retval = pselect((clientManager->fd + 1), &readFds, NULL, NULL, &timeOut, NULL);
        if (retval < 0) {
            if (errno == EINTR) {
                continue;
            } else {
                safuLogErrErrno("pselect failed!");
                result = SAFU_RESULT_FAILED;
                break;
            }
        } else if (retval > 0) {
            if (!FD_ISSET(clientManager->fd, &readFds)) {
                safuLogWarn("pselect returned with value > 0, but the selected fd has no new data!");
                continue;
            }
        } else {
            continue;
        }

        *socketFd = accept(clientManager->fd, (struct sockaddr *)&conn->addr, &addrLen);
        if (*socketFd == -1) {
            if (errno == EINTR) {
                continue;
            } else {
                safuLogErrErrno("accept failed!");
                result = SAFU_RESULT_FAILED;
                break;
            }
        } else {
            result = SAFU_RESULT_OK;
        }

        safuLogDebug("Accepted new connection");
        conn->isTrusted = elosClientAuthorizationIsTrustedConnection(&clientManager->clientAuth, &conn->addr);
        if (conn->isTrusted) {
            safuLogDebug("connection is trusted");
        } else {
            safuLogDebug("connection is not trusted");
        }
        break;
    }

    return result;
}

void *elosClientManagerThreadListen(void *ptr) {
    elosClientManager_t *clientManager = (elosClientManager_t *)ptr;
    bool active = false;
    int retVal;

    retVal = eventfd_write(clientManager->syncFd, _SYNCFD_VALUE);
    if (retVal < 0) {
        safuLogErrErrnoValue("eventfd_write failed", retVal);
    } else {
        retVal = listen(clientManager->fd, ELOS_CLIENTMANAGER_LISTEN_QUEUE_LENGTH);
        if (retVal != 0) {
            safuLogErrErrnoValue("listen failed", retVal);
        } else {
            atomic_fetch_or(&clientManager->flags, ELOS_CLIENTMANAGER_LISTEN_ACTIVE);
            active = true;
        }
    }

    while (active == true) {
        elosClientConnection_t *connection = NULL;
        safuResultE_t result = SAFU_RESULT_FAILED;
        int socketFd = -1;
        int slot = -1;

        // wait until we have a free connection slot available
        result = elosClientManagerThreadGetFreeConnectionSlot(clientManager, &slot);
        if (result != SAFU_RESULT_OK) {
            break;
        } else if (slot < 0) {
            continue;
        } else {
            connection = &clientManager->connection[slot];

            result = elosClientManagerThreadWaitForIncomingConnection(clientManager, slot, &socketFd);
            if (result != SAFU_RESULT_OK) {
                SAFU_SEM_UNLOCK(&clientManager->sharedData.connectionSemaphore, break);
            } else {
                result = elosClientConnectionStart(connection, socketFd);
                if (result != SAFU_RESULT_OK) {
                    safuLogErr("Starting client connection failed");
                    continue;
                }
            }
        }

        if (!(atomic_load(&clientManager->flags) & ELOS_CLIENTMANAGER_LISTEN_ACTIVE)) {
            active = false;
        }
    }

    if (clientManager->fd != -1) {
        retVal = close(clientManager->fd);
        if (retVal != 0) {
            safuLogWarnErrnoValue("Closing listenFd failed (possible memory leak)", retVal);
        }
    }

    atomic_fetch_and(&clientManager->flags, ~ELOS_CLIENTMANAGER_LISTEN_ACTIVE);
    atomic_fetch_or(&clientManager->flags, ELOS_CLIENTMANAGER_THREAD_NOT_JOINED);

    return NULL;
}
