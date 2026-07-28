# Focused chart tests

Run `./tests/test.sh` from the repository root or from this chart directory.
The test renders a valid two-peer configuration, verifies the lock-manager,
Vault, probe, protocol Service, ingress, policy, and monitoring hooks, checks
that missing required HA wiring fails fast, and runs kubeconform against the
rendered Kubernetes resources. Custom-resource and Prometheus resources are
skipped by kubeconform when their CRD schemas are not installed locally.
