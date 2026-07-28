package org.example.artemis.validation;

/** RPO evaluation result, which can be deferred after an ambiguous send. */
public enum RpoStatus {
    PASS("PASS"),
    FAIL("FAIL"),
    NOT_EVALUATED("NOT_EVALUATED");

    private final String reportValue;

    RpoStatus(String reportValue) {
        this.reportValue = reportValue;
    }

    public String reportValue() {
        return reportValue;
    }
}
