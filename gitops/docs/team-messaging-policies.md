# Application messaging policies

A Workload Cell selects a Profile in `argocd/topology/<environment>.yaml`.
The Profile owns named `messagingPolicies`, their defaults, and an explicit
`allowedOverrides` list. Teams select a policy on each declared destination
in `workloads/<environment>/<workloadCellName>/artemis-values.yaml`.
These are messaging behaviors, not user/role permissions.

## Follow the test example

The [test topology](../argocd/topology/test.yaml) assigns `application-messaging`
to **test-sky2**, which remains disabled. Its
[workload values](../workloads/test/test-sky2/artemis-values.yaml) contain:

- `EXAMPLE.ORDERS`: `reliable-work`, overridden to eight total delivery
  attempts and a 10-second redelivery delay.
- `EXAMPLE.NOTIFICATIONS`: `time-sensitive`, overridden to a 60-second default
  message lifetime. Retry defaults remain three attempts with a 5-second delay.

Both use durable, explicitly declared queues. The Profile configures `APP.DLA`
and `APP.EXPIRY` as recovery addresses, with automatically created queues named
`DLQ.<source-address>` and `EXP.<source-address>`. Existing cells and destinations
without a policy retain their existing behavior.

1. Choose an approved Profile in the topology. Review all its defaults when
   changing an existing cell's Profile; this selection affects the entire cell.
2. Copy a destination from the example into your cell's workload values. Change
   its address, queue name, routing type, and consumer limit for your application.
3. Select `messagingPolicy` and add only necessary `policyOverrides`:

   ```yaml
   messagingPolicy: reliable-work
   policyOverrides:
     maxDeliveryAttempts: 8
     redeliveryDelay: 10000
   ```

4. Run `make validate-topology`, `make validate-charts`, and
   `make test-topology` from the repository root. Submit the change for review
   and normal GitOps promotion. Enabling test-sky2 is a separate topology change
   after its environment prerequisites are ready.

## Team overrides and platform boundaries

| Setting | Allowed range | Policy permission |
| --- | --- | --- |
| `maxDeliveryAttempts` | 1–20 total attempts | Both example policies |
| `redeliveryDelay` | 1,000–300,000 milliseconds | Both example policies |
| `expiryDelay` | `-1`, or 1,000–604,800,000 milliseconds | `time-sensitive` only |

These initial bounds are repository policy, not Artemis engine limits or
performance guarantees. Profile defaults must also satisfy them. Platform
owners can tighten the allowlist by removing an override; cells still using it
will fail validation. Remove a local override to inherit its policy default.
Map entries deep-merge across layers; removing a local value does not remove an
inherited Profile value.

`expiryDelay` supplies a lifetime only when the producer supplies none; `-1`
disables that default, not producer-supplied expiration. Expiry is different
from failed-delivery retries and is not a timeout for an already-running
consumer. Expiry routing is always configured for policy-managed destinations,
including `reliable-work`, so producer-expired messages have a recovery path.
See [Artemis address settings](https://artemis.apache.org/components/artemis/documentation/latest/address-settings.html).

Policy defaults and DLQ/expiry names are platform-owned in the
[application-messaging Profile](../argocd/profiles/application-messaging/values.yaml).
Workload and environment layers cannot redefine `messagingPolicies`. The team
override schema excludes queue creation/deletion, recovery naming, memory,
paging, disk, HA, durability, storage, and security settings. The legacy topology
`features` field remains a separate platform-reviewed interface; it is not where
these destination overrides belong.

For policy-managed destinations, automatic application queue/address creation
and automatic deletion are disabled; queues must be durable and cannot purge
when consumers disconnect. Declare new destinations in Git. This first interface
does not support dynamic-queue Profiles or changing retry backoff multipliers.
Policies match an exact declared address, apply to all its queues, and cannot
use a wildcard to affect another application's destinations.

## Platform maintenance and verification

To create another Profile, copy an existing Profile directory, update its
`profile.yaml` name/description, and maintain its complete `values.yaml`.
Profiles do not inherit from each other. Add named policies with all required
settings and their allowlists; use an empty list to prohibit team overrides.
Keep shared capability defaults aligned when maintaining multiple Profiles.

Before promotion, verify on the authorized work computer that a failed delivery
retries and reaches the expected DLQ, an unconsumed expiring message reaches its
expiry queue, and unrelated addresses retain their policy. Confirm application
idempotency, monitoring, and the recovery/replay procedure. Local rendering
validates configuration, not broker runtime behavior. Never test live
infrastructure from this offline checkout.
