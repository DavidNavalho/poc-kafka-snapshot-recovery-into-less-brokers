package io.saxo.recovery.rewrite;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;
import org.junit.jupiter.api.Test;

class RecordRewriterTest {
    @Test
    void rewritesPartitionWhenLeaderSurvives() {
        RecordRewriter rewriter = new RecordRewriter();
        RewritePlan plan = new RewritePlan(List.of(0, 1, 2), DirectoryMode.UNASSIGNED, false);
        PartitionRecordModel partition = new PartitionRecordModel(
            "orders",
            4,
            List.of(0, 3, 6),
            List.of(0, 3, 6),
            0,
            7,
            11,
            List.of("dir-a", "dir-b", "dir-c")
        );

        RewriteOutcome outcome = rewriter.rewrite(List.of(partition), plan);

        PartitionRecordModel rewritten = assertInstanceOf(
            PartitionRecordModel.class,
            outcome.records().getFirst()
        );
        assertEquals(List.of(0), rewritten.replicas());
        assertEquals(List.of(0), rewritten.isr());
        assertEquals(0, rewritten.leaderId());
        assertEquals(8, rewritten.leaderEpoch());
        assertEquals(12, rewritten.partitionEpoch());
        assertEquals(List.of("UNASSIGNED"), rewritten.directories());
        assertEquals(1, outcome.partitionSummary().total());
        assertEquals(1, outcome.partitionSummary().rewritten());
        assertEquals(1, outcome.partitionSummary().leaderPreserved());
        assertEquals(0, outcome.partitionSummary().leaderReassigned());
        assertEquals(0, outcome.partitionSummary().missingSurvivors());
    }

    @Test
    void reassignsLeaderWhenOriginalLeaderDoesNotSurvive() {
        RecordRewriter rewriter = new RecordRewriter();
        RewritePlan plan = new RewritePlan(List.of(0, 1, 2), DirectoryMode.UNASSIGNED, false);
        PartitionRecordModel partition = new PartitionRecordModel(
            "payments",
            2,
            List.of(1, 4, 7),
            List.of(1, 4, 7),
            7,
            2,
            5,
            List.of("dir-a", "dir-b", "dir-c")
        );

        RewriteOutcome outcome = rewriter.rewrite(List.of(partition), plan);

        PartitionRecordModel rewritten = assertInstanceOf(
            PartitionRecordModel.class,
            outcome.records().getFirst()
        );
        assertEquals(List.of(1), rewritten.replicas());
        assertEquals(List.of(1), rewritten.isr());
        assertEquals(1, rewritten.leaderId());
        assertEquals(3, rewritten.leaderEpoch());
        assertEquals(6, rewritten.partitionEpoch());
        assertEquals(0, outcome.partitionSummary().leaderPreserved());
        assertEquals(1, outcome.partitionSummary().leaderReassigned());
    }

    @Test
    void failsWhenPartitionHasNoSurvivingReplicas() {
        RecordRewriter rewriter = new RecordRewriter();
        RewritePlan plan = new RewritePlan(List.of(0, 1, 2), DirectoryMode.UNASSIGNED, false);
        PartitionRecordModel partition = new PartitionRecordModel(
            "alerts",
            1,
            List.of(4, 5, 6),
            List.of(4, 5, 6),
            4,
            1,
            1,
            List.of("dir-a", "dir-b", "dir-c")
        );

        RewriteAbortException exception = assertThrows(
            RewriteAbortException.class,
            () -> rewriter.rewrite(List.of(partition), plan)
        );

        assertEquals(1, exception.missingPartitions().size());
        RewriteReport.MissingPartition missing = exception.missingPartitions().getFirst();
        assertEquals("alerts", missing.topicName());
        assertEquals(1, missing.partition());
        assertEquals(List.of(4, 5, 6), missing.originalReplicas());
        assertEquals(List.of(), missing.survivingReplicas());
    }

    @Test
    void dropsBrokerRegistrationsSoRecoveryBrokersCanRegisterFresh() {
        RecordRewriter rewriter = new RecordRewriter();
        RewritePlan plan = new RewritePlan(List.of(0, 1, 2), DirectoryMode.UNASSIGNED, false);

        RewriteOutcome outcome = rewriter.rewrite(
            List.of(
                new RegisterBrokerRecordModel(0),
                new RegisterBrokerRecordModel(3),
                new RegisterBrokerRecordModel(2)
            ),
            plan
        );

        assertEquals(0, outcome.records().size());
        assertEquals(3, outcome.recordsProcessed().total());
        assertEquals(3, outcome.recordsProcessed().byType().get("RegisterBrokerRecord"));
    }

    @Test
    void failsWhenVotersRecordExistsWithoutRewriteFlag() {
        RecordRewriter rewriter = new RecordRewriter();
        RewritePlan plan = new RewritePlan(List.of(0, 1, 2), DirectoryMode.UNASSIGNED, false);

        RewriteAbortException exception = assertThrows(
            RewriteAbortException.class,
            () -> rewriter.rewrite(List.of(new VotersRecordModel(List.of(0, 3, 6))), plan)
        );

        assertTrue(exception.getMessage().contains("--rewrite-voters"));
    }

    @Test
    void rewritesVotersRecordWhenRequested() {
        RecordRewriter rewriter = new RecordRewriter();
        RewritePlan plan = new RewritePlan(List.of(0, 1, 2), DirectoryMode.UNASSIGNED, true);

        RewriteOutcome outcome = rewriter.rewrite(List.of(new VotersRecordModel(List.of(0, 3, 6))), plan);

        VotersRecordModel voters = assertInstanceOf(VotersRecordModel.class, outcome.records().getFirst());
        assertEquals(List.of(0, 1, 2), voters.voterIds());
        assertTrue(outcome.quorum().votersRecordPresent());
        assertTrue(outcome.quorum().rewriteVotersRequested());
        assertTrue(outcome.quorum().votersRewritten());
    }

    @Test
    void warnsWhenRewriteVotersIsRequestedButNoVotersRecordExists() {
        RecordRewriter rewriter = new RecordRewriter();
        RewritePlan plan = new RewritePlan(List.of(0, 1, 2), DirectoryMode.UNASSIGNED, true);

        RewriteOutcome outcome = rewriter.rewrite(List.of(new TopicRecordModel("orders")), plan);

        assertTrue(outcome.warnings().stream().anyMatch(warning -> warning.contains("rewrite-voters")));
        assertFalse(outcome.quorum().votersRecordPresent());
        assertTrue(outcome.quorum().rewriteVotersRequested());
        assertFalse(outcome.quorum().votersRewritten());
    }
}
