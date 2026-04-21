package io.saxo.recovery.rewrite;

enum DirectoryMode {
    UNASSIGNED;

    static DirectoryMode parse(String raw) {
        try {
            return DirectoryMode.valueOf(raw);
        } catch (IllegalArgumentException exception) {
            throw new RewriteException(
                "unsupported directory mode: " + raw + " (expected UNASSIGNED)"
            );
        }
    }
}
