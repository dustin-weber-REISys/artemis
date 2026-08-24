# Workload Cell retirement

Retirement is a rare, destructive, manually approved operation. Removing or
disabling a topology entry is intentionally not a deletion workflow: the
ApplicationSet uses `applicationsSync: create-update` and
`preserveResourcesOnDeletion: true`, so topology mistakes cannot automatically
delete an Application, broker custom resource, StatefulSet, PVC, or data.

## Preconditions

Obtain the change approval, application-owner acknowledgement, retention and
legal disposition decision, final message reconciliation, backup/restore
evidence, and an exact inventory of the Application, ActiveMQArtemis resource,
StatefulSet, Services, Secrets, and PVCs. Perform live evidence collection only
from the authorized work computer and intended Kubernetes context.

## Procedure

1. Stop producers and consumers through the application-owned cutover plan.
2. Reconcile durable message IDs and capture final operational evidence.
3. Disable the Workload Cell in its environment topology file and confirm the
   generated Application remains present and its live
   resources are unchanged.
4. Under a separately approved maintenance action, remove the generated
   Application from ApplicationSet ownership before deleting any resource.
5. Delete broker and storage resources only in the approved order and only
   after the data-disposition decision explicitly covers the PVCs and backups.
6. Remove the Workload Cell from its environment topology file in a reviewed
   repository change, then render and validate all cluster adapters.
7. Record the completed evidence, retained backups, and any intentionally
   preserved resources in the change ticket.

There is no automatic PVC cleanup, retirement state machine, or implication
that a successful static render proves the live retirement was safe.
