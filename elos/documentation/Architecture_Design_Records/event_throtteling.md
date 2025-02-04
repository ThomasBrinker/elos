# Architecture Design Record - Event Throtteling

## Problem

Elos is built do receive and distribute Events from many different sources
(e.g. Scanners and Clients) to many different sinks (e.g. Clients, Backends).
This can result in rather severe problems if one of the source starts
generating thousands of Events in a very short timespan. This could be either
a malicous Program or simply a malfunctioning component like a Kernel driver
that suddenly starts dumping trace-dumps in an endless loop.

How can we ensure that Elos continues to operate safely under such conditions?

## Goals

* Improve the design to let it operate as safely as possible while under duress
* Detect attacks or malfunctioning components
* Create countermeasures, like closing a connection or shutting a scanner down
* Make sure that important Events are still processed as quickly as possible

## Excluded

Operating system and/or Kernel level countermeasures. These can be neccessary
for certain sources, like Events coming over TCP/IP connections -
These are out of scope of this ADR and have to be considered separately.

## Considerations

There are several different ways of overwhelming Elos,
which shall be viewed here before coming to a final conclusion.

### Connection flooding

Connection flooding (e.g. trying to create thousands of connections in a short
timespan) needs to be viewed and considered separately for each
connecting type (e.g. Unix, TCP/IP), as there can be big differences there -
Especially in available means to detect malicious connection attempts,
which in turn would allow us to drop or ignore certain connections.

The simplest and most universal countermeasure is to limit the amount
of connections by a configuration parameter. This comes with problem though:
While the limit keeps `elosd`, and by extension, the embedded system behind it
from being overwhelmed, any Client trying to connect to `elosd` won't be able
to do so as long as the attackers maxed out connections are still open,
preventing any further communication.

Another attack scenario might be counting the maximum amount of connections
by connecting to `elosd` until it fails, then keep closing and opening
connections as fast as possible with the counted maximum as a limit.

The simplest countermeasure here would be to add a timestamp as
a component and disable the interface completely for a certain time,
if the amount of opened/closed connections in a timeframe is too high -
Which unfortunately has the same problem as the generic connection limit.

_Any further mitigations are highly connection type dependend and need_
_to be viewed separetely each, which is out of scope of this document._

### Subscription flooding

Subscription flooding can be caused by e.g. a Client generating thousands of
subscriptions in a very short amount of time. Sadly there is no sane and safe
way of detecting malicious subscriptions, as even the most simple form,
checking for duplicated filters, is time consuming and very easily defeated
by randomizing the filter rules during subscription.

* The only way to defend against this is to limit the amount of subscriptions
a client can do via a configuration parameter.

### Data flooding

Data flooding means to publish Events with a payload of several Gigabytes,
which can easily overwhelm a target in terms of processing power,
memory bandwidth and memory capacity while it tries to parse and convert
the enormous amount of data. Especially the latter is the most dangerous here,
as it forces a system to swap or trigger its Out-Of-Memory emergency handling,
which very rarely goes well for its performance and general stability.

Unfortunately there is no sane and safe way to properly detect if a payload
is filled with gargabe or sensible data.

* The only way to defend against this type of attack is to limit the incoming
size of the Event by a configuration parameter and drop such Events at the
receiving stage before memory allocation and processing occurs.
* Additional checks need to be considered, as even Events with a size limit
can still overwhelm the memory capacity easily if enough of them are created.

### Data stalling

Data stalling is the process of interrupting an ongoing communication by
not answering a data packet, or only answering it partially by, for example,
only sending the header but not the body of the message.

The only way to mitigate this issue is to make sure any connection
related code can't be stalled by adding timeouts where neccessary.

### Event flooding

Event flooding can be caused by malicious intent or malfunctioning components,
generating a huge number of Events in very short timespans.
Like with the subscriptions, there is no sane and safe way of detecting which
Events are bad and which are not.

* This problem can be migitated by introducing a ringbuffer for each
source that has a configureable set of limitations that can be checked against
when Events are written into it. This also gives us an effective way to deal
with misbehavig components, e.g. we can react and forcible close a Client
connection in case it violates too many of the imposed limits.

### Event throtteling/prioritizing

We need to make sure that important Events are processed and passed on quickly,
even if we have DDoS attacks like described above going on.

* To make this work we need to start splitting and decoupling some of
the inner workings of the EventProcessor to allow processing of Events in
multiple threads, which will also include priotization of certain Events.

### Event merging

Sometimes even a well functioning component can generate many messages with
the same content. Ideally we can detect and merge such Events into a singular
entry. This comes with its own set of problems however in terms of how and
what we can compare, e.g. a small variable part like a timestamp within the
payload would make this a big hassle to implement. We also strongly need to
consider performance here, as operations like these can very quickly get
very expensive.

_This is out of scope of this document and needs to be carefully considered_
_with a couple of different scenarios (e.g. Syslog/Kmsg/...)._

## Design 1

The Design shall focus on the changes neccessary to mitigate the attack
scenarios above. It is important to note that this design iteratively co-evolved
with the considerations mentioned above, meaning that the considerations expanded
each time an earlier "Design 1" or potential "Design 2" ran into problems
and vice-versa. Due to this a "Design 2" that also solves all the considerations
does not exist at the time.

### Connection flooding

_As mentioned above, connection type specific countermeasures are out of scope_
_of this document, so only the basic countermeasures are handled here._

The first connection flooding scenario, opening as much connections as possible,
already has a basic mitigation in place, with the ClientManager having a maximum
connection limit defined by `CLIENT_MANAGER_MAX_CONNECTIONS`.

This implementation can be sligthly improved by moving this define
into the configuration files.
The suggested value is: `elos/ClientManager/Limits/MaximumConnections/{integer}`

The second scenario, closing and opening as many connections as possible,
currently has no countermeasures implemented. The easiest way to defend against
this is to introduce a `NewConnectionsPerSecond` Limit that is checked each time
a new connection is made and stops to listen for new connections for a specified
amount of time, while also generating an appropriate Event to be logged.
The primary goal here is to keep `elosd` operative as well as keeping it
from consuming too much processing power on the embedded system -
Losing the ability to connect to `elosd` for this time is unfortunate
but by far the lesser evil compared to everything else stalling on the target;
Already established connections will be unaffected by this.

The implementation shall use two configuration values `NewConnectionsPerSecond`
and `ConnectionFloodingTimeout`, these must be put in the same configuration
space as `MaximumConnections`. The listen loop that waits for new connections
needs to be extended by the mentioned connections-per-second counter. In case
the limit is reached, an appropriate Event shall be published, followed by a
simple wait command (e.g. `nanosleep()`) that waits for the defined time,
after which normal operation continues.

### Subscription flooding

Currently the amounts of subscriptions a client can create is not restricted.
This can be solved in a very similar fashion to connection flooding by adding
a value to the configuration file. The value can then checked every time
`elosMessageEventSubscribe` is called by comparing it against the amount
of EventQueues associated with the connection. Should the limit be reached,
and error string shall be returned to the client describing the problem.

Suggested configuration value: `elos/ClientManager/Limits/MaximumSubscriptionsPerConnection/{integer}`
Suggested error string: `"maximum amount of subscriptions per connection reached"`

### Data flooding

Currently the amounts of data a client can send is not restricted.
This can be solved in the same way as with Connection/Subscription flooding
by checking against a configuration value while receiving messages.
The value is ideally buffered in one of the shared data structeres
to make access faster, as the read function is called very often.
The suggested value is: `elos/ClientManager/Limits/MaximumDataLength/{integer}`

### Data stalling

There is currently no protection against data stalling. To solve this we need
to extend our reading and writing functions with a timeout as well as new
return codes so we can properly identify and propagate the timeout error.

The timeout value needs to be based on a configuration value, which ideally
is buffered for performance reasons. The suggest configuration value is:
`elos/ClientManager/Limits/DataSendReceiveTimeout/{sec,nsec}`

### Event flooding and Event throtteling/prioritizing

_Event flooding and Event throtteling/prioritizing are viewed together here;_
_These can't be solved independendly, as every change made for one will affect_
_the other with the way we implement the solution._

The current implementation has the EventProcessor as a singular instance when it
comes to processing Events; All sources share this instance with a single set
of filters (as well as mutexes), so it is currently relatively easy to stall
it by overwhelming it with dozens of Subscriptions or too many Events at once.

This shall be solved by, as mentioned above, restructing the EventProcessor.
as well as adding two new components that will help with handling the scenarios
mentioned above.

The new data path will roughly be as the following:
`Source -> Publish -> EventBuffer -> EventDispatcher -> EventProcessorPipeline -> Sink`

Every source (e.g. Scanner or a Client) will receive its own EventBuffer which
it can write into with Publish. A Pipeline will essentially be what
the EventProcessor currently is, a set of filters with their respective sinks
(e.g. Client, Backends, Scanner). The difference here is that we will be able
to configure and run many Pipelines in parallel, this includes fixed Pipelines
for our Backends as well as dynamic ones created for Client subscriptions.
These Pipelines shall be able to be grouped into several threads
(1..n Pipelines per thread). The EventDispatcher will run 1..n threads that are
resonsible to safely distribute the Events within the EventBuffers to the various
Pipelines, with the focus on processing the more important Events as soon as possible.

__Attention__: As these are a lot of rather complex changes we shall try to
break this overhaul down into as simple as possible chunks that are easier
to implement and that can be extended with the intended feature set later.
Based on this we're going to focus on EventBuffer and the EventDispatcher first,
with the EventProcessor following once the first two are established.

#### EventBuffer

The EventBuffer is the new publish point for Events in Clients and Scanners.
Its primary purpose is to give each Source its own RingBuffer that can be filled
without affecting any other Source, thus helping with detecting and defending
against Event flooding style attacks. Its secondary purpose is to help with
Event throtteling/prioritizing by pre-sorting Events in a way that minimizes
the work the EventDispatcher has do to - Ideally the EventDispatcher does not
need to parse the Events in any form and can focus on dispatching the available
Events by simply copying them to the different Pipelines as fast as possible.

Handling of these buffers shall be invisible to both and has to be handled
by e.g. the ClientManager and the ScannerManager. Since read/write speed is
extremely important here we won't have a centralized component managing
these Buffers, as we do not want to do an id based lookup every time we
publish an event - Instead the EventBuffer shall be a standalone component.

The EventBuffer is intended to have 1..n RingBuffers based on the Event's
priority, configured with parameters during the EventBuffers creation.
There up to two ways on how to define this priority: The Event's
`.severity` field (extremely fast to check) and by defining 1..n EventFilters,
which is extremely powerful, but could be too slow depending on how many Events
are processed per second.

_Due to the current lack of EventFilter performance data and the aforementioned_
_focus on getting the components established first, the priority handling will_
_be fleshed out in more detail once the new infrastructure is established_
_(after which it will be easy to add and test new features)._

The intial implementation shall be based on the following:

```C

// Data types
typedef elosId_t elosEventBufferId_t;

typedef struct elosEventBuffer {
    elosFlag_t          flags;
    elosEventBufferId_t id;
    pthread_mutex_t     mutex;
    safuVec_t           *eventVec;
    uint32_t            eventVecPos;
    uint32_t            limitEventCount;
    // More to follow, e.g. time limit, callbacks, priority based buffers
} elosEventBuffer_t;

typedef struct elosEventBufferParam {
    elosEventBufferId_t id;
    uint32_t            limitEventCount;
} elosEventBufferParam_t;

// Functions
safuResultE_t elosEventBufferNew(elosEventBuffer_t **eventBuffer);
safuResultE_t elosEventBufferInitialize(elosEventBuffer_t *eventBuffer, elosEventBufferParam_t param);
safuResultE_t elosEventBufferRead(elosEventBuffer_t *eventBuffer, safuVec_t **eventVec);
safuResultE_t elosEventBufferWrite(elosEventBuffer_t *eventBuffer, elosEvent_t const * const event);
safuResultE_t elosEventBufferDeleteMembers(elosEventBuffer_t *eventBuffer);
safuResultE_t elosEventBufferDelete(elosEventBuffer_t *eventBuffer);
```

_Notes_:
* `Read` shall, for now, detach the `eventVec` (much like EventQueue) and create
a new one during read.
* `Write` shall write the given Event into `eventVec`.
* `eventVec` needs to behave like a RingBuffer,
`limitEventCount` and `eventVecPos` should be used to implement the behaviour.
This may be moved into its own component in the future.

#### EventDispatcher

The main problem with giving each Source its own EventBuffer is how we get
many Events in different EventQueues to multiple EventProcessorPipelines
while keeping everything coherent - How do we know if all the Pipelines
finished reading from a given EventBuffer for example? What if one of the
Pipelines is really slow or hangs for some reason?
To circumvent these problems the EventDispatcher is added.

The EventDispatcher's main purpose is to copy Events from EventBuffers
to the various EventProcessorPipelines as quickly as possible.
Is is intended to be able to configure multiple EventDispatchers with
different priorities, with a central EventDispatcherManager that is responsible
for setting up (and cleaning up) everything.

Each EventDispatcher will run in its own thread and distributes the contents
(based on priority) from 1..n EventBuffers to 1..n EventProcessorPipelines.
Later on it is intended to be able to group several Dispatchers into a single
thread, but for the beginning every Dispatcher will run in its own thread.

The initial implementation shall be based around the following:

```C

// Data types
typedef struct elosEventDispatcher {
    elosFlag_t           flags;
    pthread_mutex_t      mutex;
    safuVec_t            eventBufferPtrVec;
    samconfConfig_t      *config;
    elosEventProcessor_t *eventProcessor;
    elosEventBufferId_t  idCount; // To be replaced later with idManager
} elosEventDispatcher_t;

typedef struct elosEventDispatcherParam {
    samconfConfig_t      *config;
    elosEventProcessor_t *eventProcessor;
} elosEventDispatcherParam_t;

// Functions
safuResultE_t elosEventDispatcherNew(elosEventDispatcher_t **eventDispatcher);
safuResultE_t elosEventDispatcherInitialize(elosEventVector_t *eventDispatcher, elosEventDispatcherParam_t param);
safuResultE_t elosEventDispatcherBufferAdd(elosEventVector_t *eventDispatcher, elosEventBuffer_t *eventBuffer, elosEventBufferId_t *eventBufferId);
safuResultE_t elosEventDispatcherBufferRemove(elosEventVector_t *eventDispatcher, elosEventBufferId_t eventBufferId);
safuResultE_t elosEventDispatcherDispatch(elosEventVector_t *eventDispatcher);
safuResultE_t elosEventDispatcherStart(elosEventVector_t *eventDispatcher);
safuResultE_t elosEventDispatcherStop(elosEventVector_t *eventDispatcher);
safuResultE_t elosEventDispatcherDeleteMembers(elosEventVector_t *eventDispatcher);
safuResultE_t elosEventDispatcherDelete(elosEventVector_t *eventDispatcher);
```

_Notes_:
* `BufferAdd` and `BufferRemove` shall be used by e.g. the ClientManager and
the ScannerManager to add and remove Buffers that the `EventDispatcher` uses.
* `Start` and `Stop` are responsible for handling the background thread that
runs the EventDispatcher.
* `Dispatch` is intended to be used internally by the background thread only,
it shall read from all Buffers in `eventBufferPtrVec` and forward them to the
`EventProcessor`.
* The EventDispatcherManager will use nearly the same set of functions
and parameters as EventDispatcher, due to this the code snippets for it
are not present here.
* The initial implementation will simply read from 1..n Buffers and pass
them on directly to the current EventProcessor to get things running.


#### EventProcessorPipeline

The EventProcessor will be reworked to have multiple configureable Pipelines,
with, as mentioned above, each Pipeline having a similiar featureset compared
to what the EventProcessor currently has.

It is intended that 1..n Pipelines run in a thread, with each Pipeline having
their own EventBuffer that is filled by EventDispatchers. Each Pipeline will
also have 1..n EventFilters as well as 1 "Sink" (e.g. a EventQueue or a Backend),
to which the Events will be passed in case one of the EventFilters matches.

The details to this component will be fleshed out in more detail once
the basic EventBuffers and EventDispatchers are established in the codebase.
