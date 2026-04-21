package io.saxo.recovery.rewrite;

import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Optional;

final class RewriteOptionsParser {
    RewriteOptions parse(String[] args) {
        Path input = null;
        Path output = null;
        String survivingBrokers = null;
        DirectoryMode directoryMode = null;
        boolean rewriteVoters = false;
        Path report = null;
        Path metadataLogInput = null;
        Path metadataLogOutput = null;
        String faultTopic = null;
        Integer faultPartition = null;
        String faultReplicas = null;

        for (int index = 0; index < args.length; index++) {
            String argument = args[index];
            switch (argument) {
                case "--input" -> input = Path.of(readValue(argument, args, ++index));
                case "--output" -> output = Path.of(readValue(argument, args, ++index));
                case "--surviving-brokers" -> survivingBrokers = readValue(argument, args, ++index);
                case "--directory-mode" -> directoryMode = DirectoryMode.parse(readValue(argument, args, ++index));
                case "--report" -> report = Path.of(readValue(argument, args, ++index));
                case "--metadata-log-input" -> metadataLogInput = Path.of(readValue(argument, args, ++index));
                case "--metadata-log-output" -> metadataLogOutput = Path.of(readValue(argument, args, ++index));
                case "--fault-topic" -> faultTopic = readValue(argument, args, ++index);
                case "--fault-partition" -> faultPartition = parseIntegerArgument(argument, readValue(argument, args, ++index));
                case "--fault-replicas" -> faultReplicas = readValue(argument, args, ++index);
                case "--rewrite-voters" -> rewriteVoters = true;
                case "--help" -> throw new RewriteException(usage());
                default -> throw new RewriteException("unknown argument: " + argument + System.lineSeparator() + usage());
            }
        }

        List<String> missing = new ArrayList<>();
        if (input == null) {
            missing.add("--input");
        }
        if (output == null) {
            missing.add("--output");
        }
        if (survivingBrokers == null) {
            missing.add("--surviving-brokers");
        }
        if (directoryMode == null) {
            missing.add("--directory-mode");
        }
        if (report == null) {
            missing.add("--report");
        }
        if (!missing.isEmpty()) {
            throw new RewriteException("missing required arguments: " + String.join(", ", missing) + System.lineSeparator() + usage());
        }
        if ((metadataLogInput == null) != (metadataLogOutput == null)) {
            throw new RewriteException(
                "metadata log rewrite requires both --metadata-log-input and --metadata-log-output" +
                    System.lineSeparator() + usage()
            );
        }
        if ((faultTopic != null) || (faultPartition != null) || (faultReplicas != null)) {
            if (faultTopic == null || faultPartition == null || faultReplicas == null) {
                throw new RewriteException(
                    "fault injection requires --fault-topic, --fault-partition, and --fault-replicas together" +
                        System.lineSeparator() + usage()
                );
            }
        }

        List<Integer> parsedFaultReplicas = faultReplicas == null ? List.of() : parseReplicaIds(faultReplicas);
        Optional<PartitionReplicaOverride> partitionReplicaOverride = Optional.empty();
        if (faultTopic != null) {
            partitionReplicaOverride = Optional.of(
                new PartitionReplicaOverride(faultTopic, faultPartition, parsedFaultReplicas, parsedFaultReplicas.getFirst())
            );
        }

        return new RewriteOptions(
            input,
            output,
            parseSurvivingBrokers(survivingBrokers),
            directoryMode,
            rewriteVoters,
            report,
            Optional.ofNullable(metadataLogInput),
            Optional.ofNullable(metadataLogOutput),
            partitionReplicaOverride
        );
    }

    String usage() {
        return """
            usage: snapshot-rewrite-tool --input <checkpoint> --output <checkpoint> \
              --surviving-brokers <csv> --directory-mode UNASSIGNED --report <json> \
              [--rewrite-voters] [--metadata-log-input <log>] [--metadata-log-output <log>] \
              [--fault-topic <topic> --fault-partition <id> --fault-replicas <csv>]
            """.stripTrailing();
    }

    private String readValue(String option, String[] args, int index) {
        if (index >= args.length) {
            throw new RewriteException("missing value for " + option + System.lineSeparator() + usage());
        }
        return args[index];
    }

    private List<Integer> parseSurvivingBrokers(String raw) {
        if (raw.isBlank()) {
            throw new RewriteException("surviving brokers list must not be empty");
        }

        String[] parts = raw.split(",");
        LinkedHashSet<Integer> parsed = new LinkedHashSet<>();
        for (String part : parts) {
            String token = part.trim();
            if (token.isEmpty()) {
                throw new RewriteException("surviving brokers list contains an empty entry");
            }

            int brokerId;
            try {
                brokerId = Integer.parseInt(token);
            } catch (NumberFormatException exception) {
                throw new RewriteException("invalid surviving broker id: " + token);
            }

            if (!parsed.add(brokerId)) {
                throw new RewriteException("duplicate surviving broker id: " + brokerId);
            }
        }

        return parsed.stream().sorted(Comparator.naturalOrder()).toList();
    }

    private int parseIntegerArgument(String option, String raw) {
        try {
            return Integer.parseInt(raw);
        } catch (NumberFormatException exception) {
            throw new RewriteException("invalid integer for " + option + ": " + raw);
        }
    }

    private List<Integer> parseReplicaIds(String raw) {
        if (raw.isBlank()) {
            throw new RewriteException("replica id list must not be empty");
        }

        String[] parts = raw.split(",");
        LinkedHashSet<Integer> parsed = new LinkedHashSet<>();
        for (String part : parts) {
            String token = part.trim();
            if (token.isEmpty()) {
                throw new RewriteException("replica id list contains an empty entry");
            }

            int brokerId;
            try {
                brokerId = Integer.parseInt(token);
            } catch (NumberFormatException exception) {
                throw new RewriteException("invalid replica id: " + token);
            }

            if (!parsed.add(brokerId)) {
                throw new RewriteException("duplicate replica id: " + brokerId);
            }
        }

        return List.copyOf(parsed);
    }
}
