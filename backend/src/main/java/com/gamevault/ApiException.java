package com.gamevault;

/** An error the client should see: HTTP status, stable machine code, safe message. */
public class ApiException extends RuntimeException {
    private static final long serialVersionUID = 1L;
    public final int status;
    public final String code;

    public ApiException(int status, String code, String message) {
        super(message);
        this.status = status;
        this.code = code;
    }

    public static ApiException badRequest(String m)   { return new ApiException(400, "validation_error", m); }
    public static ApiException unauthorized(String m) { return new ApiException(401, "unauthorized", m); }
    public static ApiException forbidden(String m)    { return new ApiException(403, "forbidden", m); }
    public static ApiException notFound(String m)     { return new ApiException(404, "not_found", m); }
    public static ApiException conflict(String m)     { return new ApiException(409, "conflict", m); }
}
