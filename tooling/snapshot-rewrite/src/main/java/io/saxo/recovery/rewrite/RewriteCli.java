package io.saxo.recovery.rewrite;

import java.io.PrintStream;

public final class RewriteCli {
    private final RewriteOptionsParser optionsParser;
    private final CheckpointFileInspector checkpointFileInspector;
    private final CheckpointSnapshotReader checkpointSnapshotReader;
    private final CheckpointRewriteEngine checkpointRewriteEngine;
    private final CheckpointSnapshotWriter checkpointSnapshotWriter;
    private final MetadataLogSegmentWriter metadataLogSegmentWriter;
    private final RewriteReportWriter reportWriter;

    public RewriteCli() {
        this(
            new RewriteOptionsParser(),
            new CheckpointFileInspector(),
            new CheckpointSnapshotReader(),
            new CheckpointRewriteEngine(),
            new CheckpointSnapshotWriter(),
            new MetadataLogSegmentWriter(),
            new RewriteReportWriter()
        );
    }

    RewriteCli(
        RewriteOptionsParser optionsParser,
        CheckpointFileInspector checkpointFileInspector,
        CheckpointSnapshotReader checkpointSnapshotReader,
        CheckpointRewriteEngine checkpointRewriteEngine,
        CheckpointSnapshotWriter checkpointSnapshotWriter,
        MetadataLogSegmentWriter metadataLogSegmentWriter,
        RewriteReportWriter reportWriter
    ) {
        this.optionsParser = optionsParser;
        this.checkpointFileInspector = checkpointFileInspector;
        this.checkpointSnapshotReader = checkpointSnapshotReader;
        this.checkpointRewriteEngine = checkpointRewriteEngine;
        this.checkpointSnapshotWriter = checkpointSnapshotWriter;
        this.metadataLogSegmentWriter = metadataLogSegmentWriter;
        this.reportWriter = reportWriter;
    }

    public static void main(String[] args) {
        int exitCode = new RewriteCli().run(args, System.out, System.err);
        if (exitCode != 0) {
            System.exit(exitCode);
        }
    }

    int run(String[] args, PrintStream stdout, PrintStream stderr) {
        RewriteOptions options;
        try {
            options = optionsParser.parse(args);
        } catch (RewriteException exception) {
            stderr.println(exception.getMessage());
            return 2;
        }

        try {
            CheckpointMetadata inputMetadata = checkpointFileInspector.inspect(options.input());
            CheckpointSnapshot inputSnapshot = checkpointSnapshotReader.read(options.input());
            RewriteExecutionResult rewriteResult = checkpointRewriteEngine.rewrite(inputSnapshot, options);
            checkpointSnapshotWriter.write(options.output(), rewriteResult.snapshot());
            if (options.metadataLogInput().isPresent()) {
                metadataLogSegmentWriter.rewrite(
                    options.metadataLogInput().orElseThrow(),
                    options.metadataLogOutput().orElseThrow(),
                    rewriteResult.snapshot(),
                    options
                );
            }
            CheckpointMetadata outputMetadata = checkpointFileInspector.inspect(options.output());
            RewriteReport report = reportWriter.success(options, inputMetadata, outputMetadata, rewriteResult.outcome());
            reportWriter.write(options.report(), report);
            stdout.println("rewrote checkpoint to " + options.output());
            if (options.metadataLogOutput().isPresent()) {
                stdout.println("rewrote metadata log to " + options.metadataLogOutput().orElseThrow());
            }
            return 0;
        } catch (RewriteAbortException exception) {
            reportWriter.write(options.report(), reportWriter.failure(options, exception));
            stderr.println(exception.getMessage());
            return 1;
        } catch (RewriteException exception) {
            reportWriter.write(options.report(), reportWriter.failure(options, exception.getMessage()));
            stderr.println(exception.getMessage());
            return 1;
        }
    }
}
