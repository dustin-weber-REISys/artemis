# Artemis on EKS

Generic reference implementation for running Apache ActiveMQ Artemis on
existing Amazon EKS clusters through Argo CD and Helm.

The target design uses:

- two synchronously replicated Artemis brokers on separate EBS volumes;
- a three-member Apache ZooKeeper ensemble for distributed activation locking;
- the open-source ArkMQ Broker Operator;
- Vault Agent Injector for runtime secrets;
- nginx ingress and Keycloak OIDC for the Artemis/Hawtio console;
- Prometheus and CloudWatch observability; and
- environment overlays for `test`, `nonprod`, and `prod`.

Read [the implementation specification](docs/implementation-spec.md) before
changing the deployment model. The specification includes the legacy
compatibility baseline, environment sizing, failure semantics, and acceptance
tests.

This repository contains generic names and placeholders only. Environment
specific hostnames, account identifiers, Vault paths, certificates, and image
registry locations must be supplied outside the shared chart defaults.
