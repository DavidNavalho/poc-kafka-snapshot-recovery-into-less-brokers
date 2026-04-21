package io.saxo.recovery.rewrite;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import java.nio.file.Path;
import org.junit.jupiter.api.Test;

class RewriteOptionsParserTest {
    @Test
    void sortsBrokerIdsAndCapturesRewriteVoters() {
        RewriteOptionsParser parser = new RewriteOptionsParser();

        RewriteOptions options = parser.parse(
            new String[] {
                "--input", "/tmp/in.checkpoint",
                "--output", "/tmp/out.checkpoint",
                "--surviving-brokers", "2,0,1",
                "--directory-mode", "UNASSIGNED",
                "--report", "/tmp/report.json",
                "--rewrite-voters"
            }
        );

        assertEquals(Path.of("/tmp/in.checkpoint"), options.input());
        assertEquals(Path.of("/tmp/out.checkpoint"), options.output());
        assertEquals(Path.of("/tmp/report.json"), options.report());
        assertEquals(DirectoryMode.UNASSIGNED, options.directoryMode());
        assertEquals(true, options.rewriteVoters());
        assertEquals(java.util.List.of(0, 1, 2), options.survivingBrokers());
        assertEquals(java.util.Optional.empty(), options.metadataLogInput());
        assertEquals(java.util.Optional.empty(), options.metadataLogOutput());
    }

    @Test
    void rejectsDuplicateBrokerIds() {
        RewriteOptionsParser parser = new RewriteOptionsParser();

        RewriteException exception = assertThrows(
            RewriteException.class,
            () -> parser.parse(
                new String[] {
                    "--input", "/tmp/in.checkpoint",
                    "--output", "/tmp/out.checkpoint",
                    "--surviving-brokers", "0,1,1",
                    "--directory-mode", "UNASSIGNED",
                    "--report", "/tmp/report.json"
                }
            )
        );

        assertEquals("duplicate surviving broker id: 1", exception.getMessage());
    }

    @Test
    void capturesOptionalMetadataLogArguments() {
        RewriteOptionsParser parser = new RewriteOptionsParser();

        RewriteOptions options = parser.parse(
            new String[] {
                "--input", "/tmp/in.checkpoint",
                "--output", "/tmp/out.checkpoint",
                "--surviving-brokers", "2,0,1",
                "--directory-mode", "UNASSIGNED",
                "--report", "/tmp/report.json",
                "--metadata-log-input", "/tmp/in.log",
                "--metadata-log-output", "/tmp/out.log",
                "--fault-topic", "recovery.default.6p",
                "--fault-partition", "0",
                "--fault-replicas", "8"
            }
        );

        assertEquals(java.util.Optional.of(Path.of("/tmp/in.log")), options.metadataLogInput());
        assertEquals(java.util.Optional.of(Path.of("/tmp/out.log")), options.metadataLogOutput());
        assertEquals(
            java.util.Optional.of(new PartitionReplicaOverride("recovery.default.6p", 0, java.util.List.of(8), 8)),
            options.partitionReplicaOverride()
        );
    }

    @Test
    void requiresMetadataLogArgumentsToBePaired() {
        RewriteOptionsParser parser = new RewriteOptionsParser();

        RewriteException exception = assertThrows(
            RewriteException.class,
            () -> parser.parse(
                new String[] {
                    "--input", "/tmp/in.checkpoint",
                    "--output", "/tmp/out.checkpoint",
                    "--surviving-brokers", "2,0,1",
                    "--directory-mode", "UNASSIGNED",
                    "--report", "/tmp/report.json",
                    "--metadata-log-input", "/tmp/in.log"
                }
            )
        );

        assertEquals(
            "metadata log rewrite requires both --metadata-log-input and --metadata-log-output" +
                System.lineSeparator() + parser.usage(),
            exception.getMessage()
        );
    }

    @Test
    void requiresFaultInjectionArgumentsToBeComplete() {
        RewriteOptionsParser parser = new RewriteOptionsParser();

        RewriteException exception = assertThrows(
            RewriteException.class,
            () -> parser.parse(
                new String[] {
                    "--input", "/tmp/in.checkpoint",
                    "--output", "/tmp/out.checkpoint",
                    "--surviving-brokers", "2,0,1",
                    "--directory-mode", "UNASSIGNED",
                    "--report", "/tmp/report.json",
                    "--fault-topic", "recovery.default.6p",
                    "--fault-partition", "0"
                }
            )
        );

        assertEquals(
            "fault injection requires --fault-topic, --fault-partition, and --fault-replicas together" +
                System.lineSeparator() + parser.usage(),
            exception.getMessage()
        );
    }
}
