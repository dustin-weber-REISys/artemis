package org.example.artemis.validation;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;

/** Tracks delivery observations without retaining message bodies. */
public final class SequenceTracker {
    private final long expectedStart;
    private final long expectedCount;
    private final Set<Long> expected;
    private final Set<Long> seen = new HashSet<>();
    private final Set<Long> duplicates = new TreeSet<>();
    private final Set<Long> redelivered = new TreeSet<>();
    private final Set<Long> unexpected = new TreeSet<>();
    private final Set<Long> reordered = new TreeSet<>();
    private final Set<String> duplicateIds = new TreeSet<>();
    private final Set<String> redeliveredIds = new TreeSet<>();
    private final Set<String> unexpectedIds = new TreeSet<>();
    private final Set<String> reorderedIds = new TreeSet<>();
    private final Map<Long, String> observedIds = new java.util.HashMap<>();
    private long lastSequence = Long.MIN_VALUE;
    private long receivedCount;

    public SequenceTracker(long expectedStart, long expectedCount) {
        if (expectedStart < 0 || expectedCount < 0) {
            throw new IllegalArgumentException("expectedStart and expectedCount must be non-negative");
        }
        this.expectedStart = expectedStart;
        this.expectedCount = expectedCount;
        this.expected = new TreeSet<>();
        for (long index = 0; index < expectedCount; index++) {
            expected.add(Math.addExact(expectedStart, index));
        }
    }

    public void observe(long sequence, String id, boolean wasRedelivered) {
        receivedCount++;
        String observedId = id == null ? Long.toString(sequence) : id;
        observedIds.putIfAbsent(sequence, observedId);
        if (!expected.contains(sequence)) {
            unexpected.add(sequence);
            unexpectedIds.add(observedId);
        }
        if (!seen.add(sequence)) {
            duplicates.add(sequence);
            duplicateIds.add(observedId);
        }
        if (wasRedelivered) {
            redelivered.add(sequence);
            redeliveredIds.add(observedId);
        }
        if (lastSequence != Long.MIN_VALUE && sequence < lastSequence) {
            reordered.add(sequence);
            reorderedIds.add(observedId);
        }
        lastSequence = sequence;
    }

    public long receivedCount() {
        return receivedCount;
    }

    public long uniqueCount() {
        return seen.size();
    }

    public List<Long> missingSequences() {
        Set<Long> missing = new TreeSet<>(expected);
        missing.removeAll(seen);
        return immutable(missing);
    }

    public List<Long> duplicateSequences() {
        return immutable(duplicates);
    }

    public List<Long> redeliveredSequences() {
        return immutable(redelivered);
    }

    public List<Long> reorderedSequences() {
        return immutable(reordered);
    }

    public List<Long> unexpectedSequences() {
        return immutable(unexpected);
    }

    public List<String> missingIds(String idPrefix) {
        return missingSequences().stream().map(sequence -> MessageIds.id(idPrefix, sequence)).toList();
    }

    public List<String> duplicateIds() {
        return immutableStrings(duplicateIds);
    }

    public List<String> redeliveredIds() {
        return immutableStrings(redeliveredIds);
    }

    public List<String> reorderedIds() {
        return immutableStrings(reorderedIds);
    }

    public List<String> unexpectedIds() {
        return immutableStrings(unexpectedIds);
    }

    public List<String> idsForSequences(List<Long> sequences, String idPrefix) {
        return sequences.stream()
                .map(sequence -> observedIds.getOrDefault(sequence, MessageIds.id(idPrefix, sequence)))
                .toList();
    }

    private static List<Long> immutable(Set<Long> values) {
        return Collections.unmodifiableList(new ArrayList<>(values));
    }

    private static List<String> immutableStrings(Set<String> values) {
        return Collections.unmodifiableList(new ArrayList<>(values));
    }
}
