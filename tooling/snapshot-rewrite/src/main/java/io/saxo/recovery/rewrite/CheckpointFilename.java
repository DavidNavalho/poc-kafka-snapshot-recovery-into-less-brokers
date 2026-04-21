package io.saxo.recovery.rewrite;

import java.util.regex.Matcher;
import java.util.regex.Pattern;

record CheckpointFilename(String basename, long offset, int epoch) {
    private static final Pattern CHECKPOINT_NAME =
        Pattern.compile("^(?<offset>\\d+)-(?<epoch>\\d+)\\.checkpoint$");

    static CheckpointFilename parse(String basename) {
        Matcher matcher = CHECKPOINT_NAME.matcher(basename);
        if (!matcher.matches()) {
            throw new RewriteException("invalid checkpoint basename: " + basename);
        }
        return new CheckpointFilename(
            basename,
            Long.parseLong(matcher.group("offset")),
            Integer.parseInt(matcher.group("epoch"))
        );
    }
}
