# Observed production ActiveMQ workload baseline

- Status: Working architecture baseline; not a capacity commitment
- Observation window: Dashboard views covering July 28-30, 2026
- Source: Manually transcribed screenshots from the current production
  ActiveMQ dashboard
- Scope: ELIS production behavior relevant to the Artemis transition

## Why this baseline matters

Production load is not one steady message rate. The screenshots show four
different conditions that the target architecture needs to address:

1. a large steady attachment footprint of about 8,300 consumers;
2. routine operational bursts that usually clear;
3. much larger overnight bursts; and
4. a persistent inventory of retained messages that appears to be operational
   hygiene debt rather than active work.

These conditions should be modeled separately. They must not be added together
and treated as one simultaneous peak unless a deliberate worst-case test calls
for that combination.

## Observed numbers

### Consumer footprint

| Metric | Observed value | Notes |
| --- | ---: | --- |
| Total attached consumers | approximately 8,300 | Fifteen-minute dashboard sample; ignores the dashboard time picker |
| Largest visible queue | 360 consumers | Point-in-time value |
| Second-largest visible queue | 274 consumers | Point-in-time value |
| Third-largest visible queue | 82 consumers | Point-in-time value |
| Other visible queues | 60 consumers each | At least eight queues were visible at this level; the dashboard list continued below the screenshot |

An Artemis consumer is not necessarily a separate TCP connection. Architecture
sizing still needs exported counts for connections, sessions, consumers per
session, selectors, protocols, and consumer-window or prefetch settings.

### Operational pending messages

| Condition | Observed value | Interpretation |
| --- | ---: | --- |
| Sampled one-day average pending | 667 | Dashboard summary |
| Current pending at the sample time | 1,328 | About twice the sampled average |
| Routine short burst | approximately 2,500-3,000 | The one-hour view shows these bursts draining within minutes |
| Sampled one-day peak pending | 19,211 | About 29 times the sampled average |
| Largest visible per-queue daily peak | 22,511 | A separate widget and sample; do not reconcile directly with the 19,211 aggregate without the source queries |
| Next visible per-queue peaks | 3,006; 2,680; 2,552; 2,005 | Shows that peak backlog can be concentrated in a small number of queues |
| Overnight pending spike | approximately 379,000 | Observed between 3:43 and 3:58 a.m. on July 29; returned close to baseline after the event |

The overnight value is a pending-message sample, not an enqueue-rate
measurement. Producer and consumer rates are required before converting it
into messages per second or a drain-time requirement.

### Retained or non-operational inventory

| Dashboard category | Pending messages |
| --- | ---: |
| Archive | approximately 249,000 |
| Temporary | approximately 54,000 |
| Legacy backend-results queue | approximately 53,900 |
| Paused | approximately 39,400 |
| Operational candidate | approximately 2,860 |
| Replay | 219 |
| **Total shown** | **approximately 399,379** |

Approximately 396,300 messages, or about 99% of the displayed inventory, were
in archive, temporary, legacy-result, or paused categories. The three largest
visible archive queues contained 81,686, 73,927, and 73,427 messages—a combined
229,040 messages.

The labels and age suggest retained or potentially abandoned work, but the
screenshots do not prove that every message is safe to delete. Application
owners must decide whether each queue should be drained, replayed, archived
outside the broker, migrated, or purged.

## Architecture implications

### Broker and client capacity

The target must remain stable with approximately 8,300 attached consumers,
including the realistic mix of idle and active consumers. Tests must measure
broker heap, direct memory, file descriptors, connection and session counts,
network utilization, thread pools, and management/metrics overhead.

The consumer total also creates a recovery concern. A broker or endpoint
recovery may cause thousands of consumers to reconnect and reattach at once.
Client retry backoff, jitter, topology discovery, authentication load, and
session recreation must be tested as part of failover rather than after it.

### Burst and backlog behavior

Routine bursts, the daily peak, and the overnight event are different test
profiles. The design should demonstrate that it can:

- absorb and drain a routine backlog of approximately 3,000 messages without
  paging or sustained latency;
- process a backlog in the 19,000-23,000 range while meeting the agreed
  recovery objective; and
- absorb an overnight event that reaches approximately 379,000 pending
  messages without producer failure, consumer starvation, or uncontrolled
  disk growth.

Message count alone cannot size storage or journal throughput. The next
baseline export needs message-size distributions, persistence and transaction
settings, enqueue/dequeue rates, acknowledgement behavior, and the duration of
each drain.

### Queue topology

The visible peak data is uneven: one queue reached more than 22,000 pending
while the next visible queues peaked near 2,000-3,000. Capacity decisions
should therefore use per-queue traffic and consumer behavior, not just a broker
aggregate. A hot queue may justify workload isolation, but only after checking
ordering, selectors, transactions, message size, consumer concurrency, and the
application's ability to scale.

### Migration and queue hygiene

The approximately 396,300 retained messages should not silently become a
permanent sizing requirement for the new platform. Before migration, every
queue needs an owner and a documented disposition:

- migrate and consume;
- replay through an approved process;
- export to durable archive storage;
- retain temporarily with an expiration date; or
- purge with owner approval and evidence.

Retention, expiry, dead-letter, replay, and ownership policies should prevent
the same inventory from accumulating after the transition. Monitoring should
separate active operational backlog from paused, archive, replay, and
dead-letter inventory so an incident is not hidden by old data.

## Required performance and recovery scenarios

| Scenario | Minimum production-derived shape | Evidence to collect |
| --- | --- | --- |
| Consumer attachment | Approximately 8,300 attached consumers using a realistic connection/session ratio | Attach success, connection and session counts, heap, direct memory, file descriptors, authentication rate |
| Routine burst | Low-hundreds baseline followed by approximately 3,000 pending | Producer acknowledgement latency, consumer latency, drain time, paging, disk and network utilization |
| Daily high backlog | 19,000-23,000 pending, concentrated according to actual per-queue distribution | Per-queue drain rate, fairness, ordering, redelivery, journal and replication behavior |
| Overnight event | Rise to approximately 379,000 pending using exported production timing and message-size distributions | Peak resource use, producer errors, paging, replication lag, recovery time, post-event correctness |
| Incident capacity envelope | 2,000,000 pending at the measured production body-size distribution, including a provisional 128-KiB body case | Per-peer stored bytes, journal and paging overhead, disk guardrail, replication synchronization, producer flow control, and drain time |
| Failover under load | Approximately 8,300 consumers attached while a routine and then overnight-derived load is active | Activation time, reconnect ramp, split-brain checks, acknowledged-message reconciliation, duplicates and redeliveries |
| Retained-data case | Approximately 396,300 retained messages only if the approved migration plan carries them forward | Startup/recovery effect, management-query latency, disk use, expiry and cleanup behavior |

The performance harness should report p50, p95, and p99 producer
acknowledgement and end-to-end latency, enqueue and dequeue rates, backlog and
message age, drain time, journal and paging I/O, replication state, JVM and
container resources, reconnect time, redeliveries, duplicates, and missing
acknowledged messages.

## Evidence gaps and next measurements

The screenshots are sufficient to shape test scenarios, but not to set final
CPU, memory, network, or storage requests. Before production sizing, export at
least seven representative days of:

- queue-level enqueue, dequeue, pending, scheduled, delivering, and consumer
  counts;
- broker connection and session counts by protocol;
- message age and message-size percentiles;
- durable versus non-durable and transactional traffic;
- producer acknowledgement and end-to-end processing latency;
- journal, paging, disk latency/IOPS, network, CPU, heap, direct memory, and
  garbage collection;
- overnight job schedules and their actual start/end times; and
- queue owner, retention class, expiry/DLQ policy, and migration disposition.

Until those exports are available, use the observed numbers as minimum
production-derived validation scenarios, not as proven production limits or
headroom targets.
