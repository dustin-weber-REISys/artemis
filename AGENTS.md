# Repository working instructions

## Execution boundary

- This checkout is an offline/test copy. The real Artemis deployment, cloud
  credentials, and operational Kubernetes contexts exist only on the user's
  work computer and are not reachable from this workspace.
- Never initiate AWS SSO, use `kubectl` or Argo against a live cluster, open a
  cloud login, deploy, or otherwise test live infrastructure from this
  workspace. A locally configured context or cached credential does not imply
  authorization or connectivity.
- For deployment incidents, work only from repository artifacts and evidence
  the user supplies from the work computer. Provide exact, read-only evidence
  collection commands for the user to run there when live state is required,
  then implement and validate repository-owned fixes locally.

## Default to implementation

- When a request reports an error, failed deployment or sync, broken behavior, or a desired application change, treat it as a request to implement the fix in this repository. Inspect the relevant code and configuration, make the appropriate edits, and validate them.
- Do not stop at diagnosis, explanation, or a runbook when a safe repository change can fix the issue or prevent it from recurring. Include necessary tests, validation, templates, automation, and concise documentation updates in the implementation.
- If part of the fix is owned by an external platform or requires live credentials, still update every applicable repository-owned artifact so the intended configuration is encoded and testable. Clearly identify only the remaining external action.
- Provide analysis without modifying files only when the user explicitly asks for analysis, explanation, review, or diagnosis without implementation.
- Preserve unrelated and pre-existing user changes. Do not commit, push, deploy, or mutate live infrastructure unless the user explicitly requests it.
