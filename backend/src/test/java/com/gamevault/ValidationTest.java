package com.gamevault;

import static org.junit.jupiter.api.Assertions.*;

import com.fasterxml.jackson.databind.JsonNode;
import java.math.BigDecimal;
import org.junit.jupiter.api.Test;

class ValidationTest {
    private static JsonNode j(String s) {
        return Json.parse(s.getBytes(java.nio.charset.StandardCharsets.UTF_8));
    }

    @Test
    void requiredStringRules() {
        assertEquals("abc", Ctx.reqStr(j("{\"a\":\"  abc \"}"), "a", 10));
        assertThrows(ApiException.class, () -> Ctx.reqStr(j("{}"), "a", 10));
        assertThrows(ApiException.class, () -> Ctx.reqStr(j("{\"a\":\"  \"}"), "a", 10));
        assertThrows(ApiException.class, () -> Ctx.reqStr(j("{\"a\":5}"), "a", 10));
        assertThrows(ApiException.class, () -> Ctx.reqStr(j("{\"a\":\"abcdefghijk\"}"), "a", 10));
    }

    @Test
    void integerRules() {
        assertEquals(7, Ctx.reqInt(j("{\"n\":7}"), "n"));
        assertNull(Ctx.optInt(j("{\"n\":null}"), "n"));
        assertThrows(ApiException.class, () -> Ctx.reqInt(j("{\"n\":\"7\"}"), "n"));
        assertThrows(ApiException.class, () -> Ctx.reqInt(j("{\"n\":7.5}"), "n"));
        assertThrows(ApiException.class, () -> Ctx.reqInt(j("{\"n\":99999999999}"), "n"));
    }

    @Test
    void numberRangeAndDates() {
        assertEquals(new BigDecimal("59.99"), Ctx.optNum(j("{\"p\":59.99}"), "p", 0, 1000));
        assertThrows(ApiException.class, () -> Ctx.optNum(j("{\"p\":-1}"), "p", 0, 1000));
        assertEquals("2026-10-31", Ctx.optDate(j("{\"d\":\"2026-10-31\"}"), "d"));
        assertThrows(ApiException.class, () -> Ctx.optDate(j("{\"d\":\"31/10/2026\"}"), "d"));
        assertThrows(ApiException.class, () -> Ctx.optDate(j("{\"d\":\"2026-02-31\"}"), "d"));
    }

    @Test
    void dateTimeIsConvertedToUtc() {
        assertEquals("2026-10-20 18:30:00", MeRoutes.utcDateTime("2026-10-20T18:30"));
        assertEquals("2026-10-20 13:00:00", MeRoutes.utcDateTime("2026-10-20T18:30:00+05:30"));
        assertEquals("2026-10-20 18:30:00", MeRoutes.utcDateTime("2026-10-20T18:30:00Z"));
        assertThrows(ApiException.class, () -> MeRoutes.utcDateTime("tomorrow"));
    }

    @Test
    void passwordPolicy() {
        assertDoesNotThrow(() -> AuthService.validatePassword("abcdefghi1"));
        assertThrows(ApiException.class, () -> AuthService.validatePassword("short1"));
        assertThrows(ApiException.class, () -> AuthService.validatePassword("onlyletterslong"));
        assertThrows(ApiException.class, () -> AuthService.validatePassword("1234567890123"));
    }

    @Test
    void rateLimiterWindow() throws Exception {
        RateLimiter r = new RateLimiter(3, 200);
        assertTrue(r.allow("a"));
        assertTrue(r.allow("a"));
        assertTrue(r.allow("a"));
        assertFalse(r.allow("a"));
        assertTrue(r.allow("b"));          // independent key
        Thread.sleep(250);
        assertTrue(r.allow("a"));          // window slid
    }
}
