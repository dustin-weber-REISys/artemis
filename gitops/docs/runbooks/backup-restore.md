# Backup and restore considerations

The live message journal is on one EBS `ReadWriteOnce` volume per broker. A
volume snapshot is not a substitute for tested broker-consistent recovery.

## Before production

- Define the retention, snapshot schedule, encryption key ownership, restore
  account, and cross-AZ/cross-region policy outside this repository.
- Confirm snapshots include journal, bindings, paging, and large-message data
  needed by the selected recovery procedure.
- Test restore into an isolated namespace with a different coordination ID.
  Never attach a restored volume to both the original and recovery broker.
- Record the last acknowledged sequence in a validation send report before and
  after restore. A zero-RPO result applies to acknowledged durable messages
  only for a run whose external ledger reconciles after the approved
  snapshot/recovery process; the send report alone is only the baseline.

## Restore outline

1. Declare the incident and stop producers according to the application
   quiesce plan.
2. Preserve the original PVCs and broker logs. Do not delete them to make a
   restore fit.
3. Restore each broker volume using the platform-approved EBS mechanism and
   mount it to the intended broker identity only.
4. Restore credentials through Vault and verify TLS/Keycloak inputs without
   printing secret values.
5. Start one broker under the approved coordination ID, verify journal
   recovery, then add the peer. Confirm ZooKeeper quorum and replication
   synchronization before reopening producers.
6. Run the validation client with the pre-incident expected range. Report
   missing, duplicate, redelivered, reordered, and unacknowledged IDs.
7. Reconcile business counts and release producers only after the application
   owner accepts the result.

Snapshot creation, EBS detach/attach, cross-AZ recovery, and RPO measurement
are EKS/AWS-only activities. The repository supplies the evidence contract and
runbook guardrails, not an AWS account-specific backup controller.
