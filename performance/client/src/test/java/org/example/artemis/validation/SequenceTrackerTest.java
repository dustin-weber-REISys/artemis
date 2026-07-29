package org.example.artemis.validation;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;

class SequenceTrackerTest {
    @Test
    void reportsMissingDuplicateRedeliveryReorderAndUnexpectedSequences() {
        SequenceTracker tracker = new SequenceTracker(10, 4);
        tracker.observe(10, "msg-10", false);
        tracker.observe(12, "msg-12", false);
        tracker.observe(10, "msg-10", true);
        tracker.observe(99, "unexpected-99", false);
        tracker.observe(11, "msg-11", false);

        assertEquals(java.util.List.of(13L), tracker.missingSequences());
        assertEquals(java.util.List.of("msg-00000000000000000013"), tracker.missingIds("msg-"));
        assertEquals(java.util.List.of(10L), tracker.duplicateSequences());
        assertEquals(java.util.List.of(10L), tracker.redeliveredSequences());
        assertEquals(java.util.List.of(10L, 11L), tracker.reorderedSequences());
        assertEquals(java.util.List.of(99L), tracker.unexpectedSequences());
        assertEquals(java.util.List.of("msg-10"), tracker.duplicateIds());
        assertEquals(java.util.List.of("msg-10"), tracker.redeliveredIds());
        assertEquals(java.util.List.of("msg-10", "msg-11"), tracker.reorderedIds());
        assertEquals(java.util.List.of("unexpected-99"), tracker.unexpectedIds());
        assertEquals(5, tracker.receivedCount());
        assertEquals(4, tracker.uniqueCount());
    }

    @Test
    void emptyExpectedRangeIsStable() {
        SequenceTracker tracker = new SequenceTracker(0, 0);

        assertEquals(java.util.List.of(), tracker.missingSequences());
        assertEquals(0, tracker.receivedCount());
    }
}
