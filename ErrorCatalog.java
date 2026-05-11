package com.garanti.notification.ntfy;

import java.util.Map;
import java.util.Set;

public final class ErrorCatalog {

    public enum Category {
        VALIDATION, PAYLOAD, AUTH, PERMANENT, CONFIG, ENCODING,
        TEMPLATE, BILLING, CONFLICT, LIMIT, RATE_LIMIT, SERVER,
        PROTOCOL, UNKNOWN
    }

    public record ErrorInfo(int code, String message, Category category, int httpStatus) {}

    private static final Map<Integer, ErrorInfo> CATALOG = Map.<Integer, ErrorInfo>ofEntries(
        // 400 - BAD REQUEST
        e(40000, "Geçersiz istek", Category.VALIDATION, 400),
        e(40001, "E-mail bildirimi etkin değil", Category.CONFIG, 400),
        e(40002, "Gecikmeli mesaj için cache kapatılamaz", Category.VALIDATION, 400),
        e(40003, "Gecikmeli e-mail desteklenmiyor", Category.VALIDATION, 400),
        e(40004, "Delay parametresi parse edilemedi", Category.VALIDATION, 400),
        e(40005, "Delay çok küçük", Category.VALIDATION, 400),
        e(40006, "Delay çok büyük", Category.VALIDATION, 400),
        e(40007, "Geçersiz priority", Category.VALIDATION, 400),
        e(40008, "Geçersiz since parametresi", Category.VALIDATION, 400),
        e(40009, "Geçersiz topic adı", Category.PERMANENT, 400),
        e(40010, "Topic adına izin verilmiyor", Category.PERMANENT, 400),
        e(40011, "Mesaj UTF-8 olmalı", Category.ENCODING, 400),
        e(40013, "Geçersiz attachment URL", Category.VALIDATION, 400),
        e(40014, "Attachment\'a izin verilmiyor", Category.CONFIG, 400),
        e(40015, "Attachment expiry hatalı", Category.VALIDATION, 400),
        e(40016, "WebSocket protokolü kullanılmıyor", Category.PROTOCOL, 400),
        e(40017, "Body geçerli message JSON olmalı", Category.PAYLOAD, 400),
        e(40018, "Actions geçersiz", Category.VALIDATION, 400),
        e(40019, "Matrix JSON geçersiz", Category.VALIDATION, 400),
        e(40021, "Geçersiz icon URL", Category.VALIDATION, 400),
        e(40022, "Signup etkin değil", Category.CONFIG, 400),
        e(40023, "Token sağlanmadı", Category.AUTH, 400),
        e(40024, "Body geçerli JSON olmalı", Category.PAYLOAD, 400),
        e(40025, "Geçersiz permission string", Category.VALIDATION, 400),
        e(40026, "Şifre onayı hatalı", Category.AUTH, 400),
        e(40031, "Kullanıcı bulunamadı", Category.AUTH, 400),
        e(40033, "Geçersiz telefon numarası", Category.VALIDATION, 400),
        e(40038, "Web push payload bozuk", Category.PAYLOAD, 400),
        e(40041, "Template sonrası mesaj çok büyük", Category.LIMIT, 400),
        e(40042, "Template için body JSON olmalı", Category.PAYLOAD, 400),
        e(40043, "Template parse edilemedi", Category.TEMPLATE, 400),
        e(40044, "Template yasaklı fonksiyon", Category.TEMPLATE, 400),
        e(40045, "Template execution başarısız", Category.TEMPLATE, 400),
        e(40046, "Geçersiz kullanıcı adı", Category.VALIDATION, 400),
        e(40049, "Geçersiz sequence ID", Category.VALIDATION, 400),
        e(40050, "Geçersiz e-mail adresi", Category.VALIDATION, 400),
        // 401 / 403 / 404
        e(40101, "Yetkilendirme gerekli", Category.PERMANENT, 401),
        e(40301, "Erişim reddedildi (ACL)", Category.PERMANENT, 403),
        e(40401, "Endpoint bulunamadı", Category.PERMANENT, 404),
        // 409 - CONFLICT
        e(40901, "Kullanıcı zaten var", Category.CONFLICT, 409),
        e(40902, "Topic ACL kuralı zaten var", Category.CONFLICT, 409),
        e(40903, "Subscription zaten var", Category.CONFLICT, 409),
        // 413 - PAYLOAD TOO LARGE
        e(41301, "Attachment çok büyük / bant genişliği bitti", Category.LIMIT, 413),
        e(41302, "Matrix request boyutu aşıldı", Category.LIMIT, 413),
        e(41303, "JSON body çok büyük", Category.LIMIT, 413),
        // 429 - TOO MANY REQUESTS
        e(42901, "Rate limit: çok fazla istek", Category.RATE_LIMIT, 429),
        e(42902, "Rate limit: çok fazla e-mail", Category.RATE_LIMIT, 429),
        e(42903, "Rate limit: çok fazla aktif subscription", Category.RATE_LIMIT, 429),
        e(42904, "Server topic limiti dolu", Category.RATE_LIMIT, 429),
        e(42905, "Günlük bant genişliği aşıldı", Category.RATE_LIMIT, 429),
        e(42908, "Günlük mesaj kotası doldu", Category.RATE_LIMIT, 429),
        e(42909, "Çok fazla auth hatası", Category.RATE_LIMIT, 429),
        // 500 / 507
        e(50001, "ntfy internal error", Category.SERVER, 500),
        e(50002, "ntfy invalid path", Category.SERVER, 500),
        e(50003, "ntfy base-url config eksik", Category.SERVER, 500),
        e(50004, "Web push gönderilemedi", Category.SERVER, 500),
        e(50701, "UnifiedPush'ta aktif subscriber yok", Category.SERVER, 507)
    );

    private static Map.Entry<Integer, ErrorInfo> e(int code, String msg, Category cat, int http) {
        return Map.entry(code, new ErrorInfo(code, msg, cat, http));
    }

    public static ErrorInfo describe(Integer code) {
        if (code == null) {
            return new ErrorInfo(0, "Bilinmeyen ntfy hatası", Category.UNKNOWN, 0);
        }
        ErrorInfo known = CATALOG.get(code);
        if (known != null) return known;

        // Bilinmeyen kod - HTTP kısmını çıkar
        int http = Integer.parseInt(String.valueOf(code).substring(0, 3));
        return new ErrorInfo(code, "Tanımsız ntfy hatası (HTTP " + http + ")",
            Category.UNKNOWN, http);
    }

    public static boolean isPermanent(Integer code) {
        var info = describe(code);
        return info.category() == Category.PERMANENT
            || info.category() == Category.AUTH
            || info.category() == Category.VALIDATION
            || info.category() == Category.PAYLOAD
            || info.category() == Category.CONFIG
            || info.category() == Category.TEMPLATE
            || info.category() == Category.ENCODING;
    }

    public static boolean isRetryable(Integer code) {
        return !isPermanent(code);
    }

    private NtfyErrorCatalog() {}
}
