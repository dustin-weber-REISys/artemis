# Focused chart tests

Run `./tests/test.sh` from the repository root or from this chart directory.
The test requires `helm`, `rg`, `yq`, and `kubeconform`.
The test renders a valid two-peer configuration, verifies the lock-manager,
fixed deployment invariants, per-source dead-letter queue policy, Vault,
console probes, protocol Services, ingress, policy, and monitoring hooks. It
also verifies that removed constant values are rejected and that overriding or
disabling an acceptor stays consistent across the broker custom resource,
Services, and client NetworkPolicy ports. Message expiry is confirmed absent
by default and complete when explicitly enabled; missing HA wiring fails fast.
The final render is checked with kubeconform.
Custom-resource and Prometheus resources are skipped by kubeconform when their
CRD schemas are not installed locally.
