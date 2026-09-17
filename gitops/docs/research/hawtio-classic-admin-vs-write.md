# Hawtio and ActiveMQ Classic: `ADMIN` versus `READ,WRITE`

Research date: 2026-09-01  
Scope: official Hawtio and Apache ActiveMQ documentation/source, plus the
ActiveMQ Classic Hawtio plugin source. The attached cookbook JSON is treated as
repository-external custom policy.

## Short answer

Do **not** interpret the screenshot's `ADMIN` as merely "write plus delete
queue," or assume that Hawtio supplies that hierarchy.

ActiveMQ Classic's broker destination permissions are three independent ACLs:
`read` authorizes consuming, `write` authorizes producing/sending, and `admin`
authorizes creating and removing destinations. The broker source checks the
admin ACL when a destination is added or removed, the read ACL when a consumer
is added, and the write ACL when a producer sends. It does not make `admin` an
automatic superset of `read` and `write`; full access is conventionally granted
by assigning all three. ([ActiveMQ `AuthorizationBroker`](https://github.com/apache/activemq/blob/activemq-6.2.7/activemq-broker/src/main/java/org/apache/activemq/security/AuthorizationBroker.java),
[ActiveMQ security configuration](https://activemq.apache.org/components/classic/documentation/security))

Hawtio itself also does not translate a role name into per-operation rights.
Its official documentation says `hawtio.roles` is an authentication/login role
check and is not applied to individual MBeans, attributes, or methods. Actual
management authorization must come from the runtime's RBAC implementation or
the Jolokia policy. ([Hawtio security](https://hawt.io/docs/security.html#generic-configuration-properties))

Therefore, the private cookbook's `access: "ADMIN"` and
`access: "READ,WRITE"` are a custom vocabulary. Their exact expansion cannot
be proven from the screenshot or from standard Hawtio/ActiveMQ semantics; the
code that renders or enforces that JSON is the authoritative source.

## What the pictured queue actions actually invoke

The current ActiveMQ Classic Hawtio plugin sends these Jolokia JMX operations:

| Hawtio action | ActiveMQ Classic MBean operation |
| --- | --- |
| Move message | `moveMessageTo(...)` |
| Copy message | `copyMessageTo(...)` |
| Remove message | `removeMessage(...)` |
| Retry message | `retryMessage(...)` |
| Remove group | `removeMessageGroup(...)` |
| Send message | `sendTextMessage(...)` |
| Pause / resume | `pause()` / `resume()` |
| Purge | `purge()` |
| Delete queue | broker `removeQueue(...)` |

Source: [ActiveMQ Classic Hawtio queue operations](https://github.com/afurlane/activemq-classic-hawtio/blob/master/frontend/src/services/activemq/operations/queues.ts).

These are **management-plane `exec` calls**, not ordinary JMS consume/produce
actions. Several use ActiveMQ's internal broker administration connection
context, and others manipulate the queue directly. Consequently, destination
`read`/`write`/`admin` ACLs alone are not a reliable control boundary for the
Hawtio buttons; the Jolokia/JMX policy must authorize the individual methods.
([`QueueView`](https://github.com/apache/activemq/blob/activemq-6.2.7/activemq-broker/src/main/java/org/apache/activemq/broker/jmx/QueueView.java),
[`BrokerView`](https://github.com/apache/activemq/blob/activemq-6.2.7/activemq-broker/src/main/java/org/apache/activemq/broker/jmx/BrokerView.java),
[`BrokerSupport`](https://github.com/apache/activemq/blob/activemq-6.2.7/activemq-broker/src/main/java/org/apache/activemq/util/BrokerSupport.java))

ActiveMQ Classic 6.2.7's shipped `jolokia-access.xml` treats every pictured
operation as privileged/destructive: it denies `purge`, message remove/copy/
move/retry, group removal, message send, pause/resume, and broker `removeQueue`.
The default policy is not role-sensitive; it denies those operation names at
the Jolokia boundary. ([ActiveMQ 6.2.7 Jolokia policy](https://github.com/apache/activemq/blob/activemq-6.2.7/assembly/src/release/conf/jolokia-access.xml))

## Least-privilege conclusion

For a human who only needs to inspect queues and messages, grant read-only
management access (`read`, `search`, `list`, and safe browse/getter operations),
not the cookbook's `READ,WRITE` role. Every button in the screenshot changes
broker state; none belongs in a monitoring-only role.

If operators genuinely need message remediation, create or retain a narrowly
scoped management role that allowlists only the required MBean methods and
queue-name patterns. For example, retry/move may be justified without granting
`purge`, `removeQueue`, broker stop/restart, connector changes, or arbitrary
MBean execution. Use the broad `ADMIN` mapping only for the small group that
needs destination lifecycle or broker-wide administration.

Before changing the cookbook mapping, inspect the renderer/enforcer for this
JSON and the deployed `jolokia-access.xml` on the work system. The decisive
test is the effective JMX method allowlist for each role, not whether Hawtio
renders a button.

## Version floor

Do not evaluate this separation on a vulnerable default web-console policy.
Apache reports that low-privilege web-console users could reach administrative
paths before Classic `5.19.8` and `6.2.7`; upgrade to at least one of those
versions. An earlier related issue allowed low-privilege web users to invoke
broker-management operations through the default Jolokia policy before
`5.19.7` and `6.2.6`.
([CVE-2026-49877](https://activemq.apache.org/security-advisories.data/CVE-2026-49877-announcement.txt),
[CVE-2026-49157](https://activemq.apache.org/security-advisories.data/CVE-2026-49157-announcement.txt))
