package io.saxo.recovery.rewrite;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.DigestInputStream;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;

final class CheckpointFileInspector {
    CheckpointMetadata inspect(Path path) {
        if (!Files.isRegularFile(path)) {
            throw new RewriteException("input checkpoint does not exist: " + path);
        }

        CheckpointFilename checkpointFilename = CheckpointFilename.parse(path.getFileName().toString());
        return new CheckpointMetadata(
            path.toAbsolutePath().normalize().toString(),
            checkpointFilename.basename(),
            checkpointFilename.offset(),
            checkpointFilename.epoch(),
            sha256(path)
        );
    }

    void copy(Path input, Path output) {
        try {
            Path parent = output.toAbsolutePath().normalize().getParent();
            if (parent != null) {
                Files.createDirectories(parent);
            }
            Files.copy(input, output);
        } catch (IOException exception) {
            throw new RewriteException("failed to write output checkpoint: " + output);
        }
    }

    private String sha256(Path path) {
        MessageDigest digest;
        try {
            digest = MessageDigest.getInstance("SHA-256");
        } catch (NoSuchAlgorithmException exception) {
            throw new IllegalStateException("SHA-256 not available", exception);
        }

        try (InputStream inputStream = Files.newInputStream(path);
             DigestInputStream digestStream = new DigestInputStream(inputStream, digest)) {
            byte[] buffer = new byte[8192];
            while (digestStream.read(buffer) != -1) {
                // The digest is updated by the stream wrapper.
            }
        } catch (IOException exception) {
            throw new RewriteException("failed to read checkpoint: " + path);
        }

        return HexFormat.of().formatHex(digest.digest());
    }
}
