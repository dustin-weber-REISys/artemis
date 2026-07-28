package org.example.artemis.validation;

/** Validation property asserted by a report. */
public enum Claim {
    SAFETY("safety");

    private final String reportValue;

    Claim(String reportValue) {
        this.reportValue = reportValue;
    }

    public String reportValue() {
        return reportValue;
    }
}
