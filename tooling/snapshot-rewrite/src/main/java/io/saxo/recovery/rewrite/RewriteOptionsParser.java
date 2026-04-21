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

        return new RewriteOptions(
            input,
            output,
            parseSurvivingBrokers(survivingBrokers),
            directoryMode,
            rewriteVoters,
            report,
            Optional.ofNullable(metadataLogInput),
            Optional.ofNullable(metadataLogOutput)
        );
    }

    String usage() {
        return """
            usage: snapshot-rewrite-tool --input <checkpoint> --output <checkpoint> \
              --surviving-brokers <csv> --directory-mode UNASSIGNED --report <json> \
              [--rewrite-voters] [--metadata-log-input <log>] [--metadata-log-output <log>]
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
}
