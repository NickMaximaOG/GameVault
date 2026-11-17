package com.gamevault;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.core.JsonGenerator;

public final class Json {
    public static final ObjectMapper MAPPER = new ObjectMapper()
            .enable(JsonGenerator.Feature.WRITE_BIGDECIMAL_AS_PLAIN);

    private Json() {}

    public static byte[] write(Object o) {
        try {
            return MAPPER.writeValueAsBytes(o);
        } catch (JsonProcessingException e) {
            throw new IllegalStateException(e);
        }
    }

    public static JsonNode parse(byte[] bytes) {
        try {
            return MAPPER.readTree(bytes);
        } catch (java.io.IOException e) {
            throw ApiException.badRequest("Request body is not valid JSON");
        }
    }
}
