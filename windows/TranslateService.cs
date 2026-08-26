using System.Net.Http;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace Snippr;

/// Free Google translate endpoint (gtx). Only called when the user
/// explicitly presses Translate — nothing is sent automatically.
///
/// Platform-free on purpose: ParityGate compiles this file on macOS.
/// WinForms wiring lives in `TextResultForm`; the panel (W2b) reads the
/// same Failure.UserMessage and the same TranslateAsync.
static class TranslateService
{
    public static readonly (string Code, string Label)[] Languages =
    {
        ("vi", "Tiếng Việt"), ("en", "English"), ("ja", "日本語"), ("ko", "한국어"),
        ("zh-CN", "中文 (简体)"), ("fr", "Français"), ("de", "Deutsch"),
        ("es", "Español"), ("th", "ไทย"),
    };

    /// Cap the wait the user stares at "Đang dịch…". HttpClient's default is
    /// 100s, which looks identical to a hang on a blocked gtx endpoint.
    public static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(12);

    static readonly HttpClient Http = new() { Timeout = RequestTimeout };

    /// The timeout the live client actually uses — same constant, so a
    /// mutation of either the named value or the client itself is visible.
    public static TimeSpan ClientTimeout => Http.Timeout;

    /// Test seam. Gates drive the real translate flow without a network call,
    /// and without production growing a second code path they could pass against.
    public static Func<string, string, Task<string>>? TranslatorOverrideForTesting;

    /// Which string a translate attempt sends. Always the OCR original
    /// (`source`). `displayed` is the box the user sees, which may already
    /// be a translation — sending it stacks. An empty source is the only
    /// fallback, for a typed-only box that has nothing else to send.
    public static string RequestText(string source, string displayed) =>
        source.Length > 0 ? source : displayed;

    /// Why a translation did not land. The window keeps the `"Dịch thất bại"`
    /// prefix so a fail-open gate still matches, then names the class so a
    /// screenshot tells offline apart from 429, HTML-instead-of-JSON, or a
    /// hung request. No stack traces — this string is what the user reads.
    public sealed class Failure : Exception, IEquatable<Failure>
    {
        public enum Kind { Offline, Timeout, Http, Payload, Other }

        public Kind Class { get; }
        public int? Status { get; }

        Failure(Kind kind, int? status, string message) : base(message)
        {
            Class = kind;
            Status = status;
        }

        /// Pure: not attached to any form. The old window and the W2 panel
        /// both read this so triage tokens stay identical to macOS.
        public string UserMessage => Message;

        public static Failure Offline() =>
            new(Kind.Offline, null, "Dịch thất bại — mất mạng");

        public static Failure Timeout() =>
            new(Kind.Timeout, null, "Dịch thất bại — hết thời gian");

        public static Failure Http(int status) =>
            new(Kind.Http, status, HttpMessage(status));

        public static Failure Payload(int? status) =>
            new(Kind.Payload, status, status is int s
                ? $"Dịch thất bại — dữ liệu lạ (HTTP {s})"
                : "Dịch thất bại — dữ liệu lạ");

        public static Failure Other() =>
            new(Kind.Other, null, "Dịch thất bại — kiểm tra mạng");

        static string HttpMessage(int status) =>
            status is 429 or 403 or 401
                ? $"Dịch thất bại — bị chặn-giới hạn (HTTP {status})"
                : $"Dịch thất bại — HTTP {status}";

        public static Failure Classify(Exception error)
        {
            for (var e = error; e != null; e = e.InnerException)
            {
                if (e is Failure f) return f;
                if (e is TimeoutException) return Timeout();
                if (e is OperationCanceledException) return Timeout();
                if (e is HttpRequestException http)
                {
                    if (http.HttpRequestError is HttpRequestError.NameResolutionError
                        or HttpRequestError.ConnectionError)
                        return Offline();
                    if (http.StatusCode is { } code)
                        return Http((int)code);
                }
                if (e is SocketException sock)
                {
                    if (sock.SocketErrorCode is SocketError.TimedOut)
                        return Timeout();
                    if (IsOfflineSocket(sock)) return Offline();
                }
            }
            return Other();
        }

        static bool IsOfflineSocket(SocketException s) => s.SocketErrorCode switch
        {
            SocketError.HostNotFound => true,
            SocketError.HostUnreachable => true,
            SocketError.NetworkUnreachable => true,
            SocketError.NetworkDown => true,
            SocketError.AddressNotAvailable => true,
            SocketError.TryAgain => true,
            SocketError.NoRecovery => true,
            SocketError.NoData => true,
            SocketError.ConnectionRefused => true,
            SocketError.ConnectionReset => true,
            _ => false,
        };

        public bool Equals(Failure? other) =>
            other is not null && Class == other.Class && Status == other.Status;

        public override bool Equals(object? obj) => obj is Failure f && Equals(f);

        public override int GetHashCode() => HashCode.Combine(Class, Status);

        public static bool operator ==(Failure? a, Failure? b) => Equals(a, b);

        public static bool operator !=(Failure? a, Failure? b) => !Equals(a, b);
    }

    /// Shared by the live request and by gates: HTTP ≠ 2xx is a status, a
    /// 200 that is not the gtx JSON array is a payload, and an empty sentence
    /// list is the same payload — not a silent success.
    public static string DecodeTranslation(string body, int? httpStatus)
    {
        if (httpStatus is int status && (status < 200 || status >= 300))
            throw Failure.Http(status);
        try
        {
            using var doc = JsonDocument.Parse(
                string.IsNullOrEmpty(body) ? "null" : body);
            if (doc.RootElement.ValueKind != JsonValueKind.Array
                || doc.RootElement.GetArrayLength() == 0)
                throw Failure.Payload(httpStatus);
            var sentences = doc.RootElement[0];
            if (sentences.ValueKind != JsonValueKind.Array)
                throw Failure.Payload(httpStatus);
            var sb = new StringBuilder();
            foreach (var seg in sentences.EnumerateArray())
            {
                if (seg.ValueKind == JsonValueKind.Array
                    && seg.GetArrayLength() > 0
                    && seg[0].ValueKind == JsonValueKind.String)
                    sb.Append(seg[0].GetString());
            }
            if (sb.Length == 0) throw Failure.Payload(httpStatus);
            return sb.ToString();
        }
        catch (Failure)
        {
            throw;
        }
        catch (JsonException)
        {
            throw Failure.Payload(httpStatus);
        }
    }

    public static async Task<string> TranslateAsync(string text, string lang)
    {
        try
        {
            if (TranslatorOverrideForTesting is { } overrideFn)
                return await overrideFn(text, lang);

            // POST with the text in the body: a GET URL breaks past ~8 KB,
            // which is exactly the dense/scroll captures where translation
            // matters most.
            var url = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl="
                + Uri.EscapeDataString(lang) + "&dt=t";
            using var body = new FormUrlEncodedContent(
            [
                new KeyValuePair<string, string>("q", text),
            ]);
            using var resp = await Http.PostAsync(url, body);
            var json = await resp.Content.ReadAsStringAsync();
            return DecodeTranslation(json, (int)resp.StatusCode);
        }
        catch (Failure)
        {
            throw;
        }
        catch (Exception ex)
        {
            throw Failure.Classify(ex);
        }
    }
}
