# Repository working instructions

## Default to implementation

- When a request reports an error, failed deployment or sync, broken behavior, or a desired application change, treat it as a request to implement the fix in this repository. Inspect the relevant code and configuration, make the appropriate edits, and validate them.
- Do not stop at diagnosis, explanation, or a runbook when a safe repository change can fix the issue or prevent it from recurring. Include necessary tests, validation, templates, automation, and concise documentation updates in the implementation.
- If part of the fix is owned by an external platform or requires live credentials, still update every applicable repository-owned artifact so the intended configuration is encoded and testable. Clearly identify only the remaining external action.
- Provide analysis without modifying files only when the user explicitly asks for analysis, explanation, review, or diagnosis without implementation.
- Preserve unrelated and pre-existing user changes. Do not commit, push, deploy, or mutate live infrastructure unless the user explicitly requests it.
