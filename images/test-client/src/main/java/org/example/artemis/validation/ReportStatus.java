package org.example.artemis.validation;

/** Overall validation result. */
public enum ReportStatus {
    PASS("PASS"),
    FAIL("FAIL");

    private final String reportValue;

    ReportStatus(String reportValue) {
        this.reportValue = reportValue;
    }

    public String reportValue() {
        return reportValue;
    }
}
