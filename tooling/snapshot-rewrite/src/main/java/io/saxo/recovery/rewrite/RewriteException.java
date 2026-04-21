package io.saxo.recovery.rewrite;

final class RewriteException extends RuntimeException {
    RewriteException(String message) {
        super(message);
    }

    RewriteException(String message, Throwable cause) {
        super(message, cause);
    }
}
