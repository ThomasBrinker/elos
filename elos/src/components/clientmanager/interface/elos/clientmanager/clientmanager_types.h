// SPDX-License-Identifier: MIT
#pragma once

#include <netinet/in.h>
#include <pthread.h>
#include <safu/flags.h>
#include <samconf/samconf_types.h>
#include <stddef.h>

#include "elos/clientmanager/clientauthorization_types.h"
#include "elos/clientmanager/clientconnection_types.h"
#include "elos/eventbuffer/types.h"
#include "elos/eventdispatcher/types.h"
#include "elos/eventfilter/eventfilter_types.h"
#include "elos/eventlogging/LogAggregatorTypes.h"
#include "elos/eventprocessor/types.h"

#define ELOS_CLIENTMANAGER_CONNECTION_LIMIT    200
#define ELOS_CLIENTMANAGER_LISTEN_QUEUE_LENGTH 200

#define ELOS_CLIENTMANAGER_LISTEN_ACTIVE     (SAFU_FLAG_CUSTOM_START_BIT << 0)
#define ELOS_CLIENTMANAGER_CONNECTION_ACTIVE (SAFU_FLAG_CUSTOM_START_BIT << 1)
#define ELOS_CLIENTMANAGER_THREAD_NOT_JOINED (SAFU_FLAG_CUSTOM_START_BIT << 2)

#ifndef ELOS_CLIENTMANAGER_EVENTFILTERNODEIDVECTOR_SIZE
#define ELOS_CLIENTMANAGER_EVENTFILTERNODEIDVECTOR_SIZE 4
#endif

#ifndef ELOS_CLIENTMANAGER_EVENTQUEUEIDVECTOR_SIZE
#define ELOS_CLIENTMANAGER_EVENTQUEUEIDVECTOR_SIZE 4
#endif

/*******************************************************************
 * Data structure of a ClientManager

 * Members:
 *   flags: State bits of the component (e.g. initialized, active, e.t.c.)
 *   fd: listener socket used for waiting for new connections
 *   syncFd: eventfd used for synchronization with the worker thread
 *   addr: Address information of the listener socket
 *   connection: Array of ClientConnections
 *   connectionLimit: Size of the ClientConnections array
 *   listenThread: worker thread used by pthread_* functions
 *   sharedData: Data shared between all ClientConnections
 *   clientAuth: Client authorization functionality
 ******************************************************************/
typedef struct elosClientManager {
    safuFlags_t flags;
    int fd;
    int syncFd;
    struct sockaddr_in addr;
    elosClientConnection_t connection[ELOS_CLIENTMANAGER_CONNECTION_LIMIT];
    pthread_t listenThread;
    elosClientConnectionSharedData_t sharedData;
    elosClientAuthorization_t clientAuth;
} elosClientManager_t;

/*******************************************************************
 * Initialization parameters for a new ClientManager
 *
 * Members:
 *   config: Static configuration variables
 *   eventDispatcher: Used for registering the EventBuffers of each ClientConnection
 *   eventProcessor: Used for FilterNode/EventQueue handling
 *   logAggregator: Used for persistent logging of Events
 ******************************************************************/
typedef struct elosClientManagerParam {
    samconfConfig_t *config;
    elosEventDispatcher_t *eventDispatcher;
    elosEventProcessor_t *eventProcessor;
    elosLogAggregator_t *logAggregator;
} elosClientManagerParam_t;
