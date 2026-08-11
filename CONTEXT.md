# Artemis Platform

This context describes the independently managed messaging capacity and release progression provided by the Artemis platform.

## Language

**Workload Cell**:
Independently managed Artemis capacity for one logical environment and traffic class, composed of one active broker, one passive broker, and one persistent volume per peer.
_Avoid_: Artemis deployment, broker deployment

**Workload Cell Profile**:
A named, approved set of optional broker capabilities and operating policy shared by one or more Workload Cells.
_Avoid_: Team override, Helm values

**Platform Release**:
The centrally selected, mutually compatible versions of the Artemis broker, ArkMQ operator, ZooKeeper, and Kubernetes platform assumptions.
_Avoid_: Per-cell version, environment version

**Release Promotion**:
Advancement of one Platform Release through the test, non-production, and production clusters after the required validation succeeds.
_Avoid_: Per-cell upgrade
