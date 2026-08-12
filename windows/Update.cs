using System.Diagnostics;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;

namespace Snippr;

/// Checks the site's version.json; on confirmation downloads the installer,
/// verifies its integrity (sha256 from the manifest and/or an Authenticode
/// signature) before running it, then exits. An update that can't be verified
/// is refused rather than executed.
static class UpdateChecker
{
    const string ManifestUrl = "https://snippr.pages.dev/version.json";
    const long MaxInstallerBytes = 300_000_000;

    // The installer URL from the manifest must live on one of these hosts, so a
    // tampered manifest can't redirect the download to an arbitrary origin.
    static readonly string[] AllowedHosts =
        { "snippr.pages.dev", "github.com", "objects.githubusercontent.com" };

    public static async void Check(bool manual)
    {
        try
        {
            using var http = new HttpClient();
            var json = await http.GetStringAsync(ManifestUrl + "?t=" + Environment.TickCount64);
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            var remote = root.GetProperty("win").GetString() ?? "0";
            var url = root.GetProperty("winUrl").GetString();
            var sha = root.TryGetProperty("winSha256", out var shaEl) ? shaEl.GetString() : null;
            var current = Application.ProductVersion.Split('+')[0];

            if (url == null || !IsNewer(remote, current))
            {
                if (manual) ToastForm.Show($"Snippr {current} là bản mới nhất ✓");
                return;
            }

            if (!IsAllowedUrl(url))
            {
                if (manual) ToastForm.Show("Địa chỉ bản cập nhật không hợp lệ — bỏ qua");
                return;
            }

            var answer = MessageBox.Show(
                $"Snippr {remote} đã có bản mới (bạn đang dùng {current}).\n\n" +
                "Tải và chạy trình cài đặt ngay? App sẽ tự đóng để cập nhật.",
                "Snippr Update", MessageBoxButtons.YesNo, MessageBoxIcon.Information);
            if (answer != DialogResult.Yes) return;

            ToastForm.Show("Đang tải bản cập nhật…");
            var tmp = Path.Combine(Path.GetTempPath(), "SnipprSetup-update.exe");
            if (!await Download(http, url, tmp))
            {
                ToastForm.Show("Tải bản cập nhật thất bại");
                return;
            }

            if (!VerifyInstaller(tmp, sha))
            {
                TryDelete(tmp);
                ToastForm.Show("Bản cập nhật không xác minh được — hãy tải thủ công từ snippr.pages.dev");
                return;
            }

            Process.Start(new ProcessStartInfo(tmp) { UseShellExecute = true });
            TrayContext.Instance?.QuitApp();
        }
        catch
        {
            if (manual) ToastForm.Show("Không kiểm tra được bản mới — thử lại sau");
        }
    }

    static bool IsAllowedUrl(string url) =>
        Uri.TryCreate(url, UriKind.Absolute, out var u)
        && u.Scheme == Uri.UriSchemeHttps
        && AllowedHosts.Contains(u.Host, StringComparer.OrdinalIgnoreCase);

    /// Streams the body to disk with a size cap (no whole-file buffering in RAM).
    static async Task<bool> Download(HttpClient http, string url, string dest)
    {
        try
        {
            using var resp = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead);
            resp.EnsureSuccessStatusCode();
            if (resp.Content.Headers.ContentLength is long len && len > MaxInstallerBytes)
                return false;
            await using var stream = await resp.Content.ReadAsStreamAsync();
            await using var fs = File.Create(dest);
            var buffer = new byte[1 << 20];
            long total = 0;
            int read;
            while ((read = await stream.ReadAsync(buffer)) > 0)
            {
                total += read;
                if (total > MaxInstallerBytes) return false;
                await fs.WriteAsync(buffer.AsMemory(0, read));
            }
            return total > 0;
        }
        catch
        {
            return false;
        }
    }

    /// Establishes integrity before we execute the file:
    ///  - if the manifest published a sha256, it MUST match;
    ///  - the file's Authenticode signature, if present, MUST be valid;
    ///  - an unsigned file with no matching sha256 is refused (nothing vouches
    ///    for it), which is the case the old "download and run" code allowed.
    static bool VerifyInstaller(string path, string? expectedSha)
    {
        bool shaProvided = !string.IsNullOrWhiteSpace(expectedSha);
        bool shaOk = false;
        if (shaProvided)
        {
            shaOk = string.Equals(Sha256Hex(path), expectedSha!.Trim(),
                StringComparison.OrdinalIgnoreCase);
            if (!shaOk) return false; // manifest claims a hash and it doesn't match
        }

        uint trust = Authenticode.Verify(path);
        bool signedAndTrusted = trust == 0;
        bool unsigned = trust == Authenticode.TrustNoSignature;
        if (!signedAndTrusted && !unsigned) return false; // signed but signature invalid/untrusted

        // Passed if the code signature is valid, or (unsigned) a manifest sha matched.
        return signedAndTrusted || shaOk;
    }

    static string Sha256Hex(string path)
    {
        using var sha = SHA256.Create();
        using var fs = File.OpenRead(path);
        return Convert.ToHexString(sha.ComputeHash(fs)).ToLowerInvariant();
    }

    static void TryDelete(string path)
    {
        try { File.Delete(path); } catch { }
    }

    static bool IsNewer(string a, string b) =>
        Version.TryParse(a, out var va) && Version.TryParse(b, out var vb) && va > vb;
}

/// Minimal WinVerifyTrust wrapper: validates a file's Authenticode signature
/// against the file's contents (the only API that checks the signature matches
/// the bytes, unlike merely reading the embedded certificate).
static class Authenticode
{
    public const uint TrustNoSignature = 0x800B0100; // TRUST_E_NOSIGNATURE

    static readonly Guid GenericVerifyV2 = new("00AAC56B-CD44-11d0-8CC2-00C04FC295EE");

    const uint WTD_UI_NONE = 2;
    const uint WTD_REVOKE_NONE = 0;
    const uint WTD_CHOICE_FILE = 1;
    const uint WTD_STATEACTION_VERIFY = 1;
    const uint WTD_STATEACTION_CLOSE = 2;

    [StructLayout(LayoutKind.Sequential)]
    struct WINTRUST_FILE_INFO
    {
        public uint cbStruct;
        [MarshalAs(UnmanagedType.LPWStr)] public string pcwszFilePath;
        public IntPtr hFile;
        public IntPtr pgKnownSubject;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct WINTRUST_DATA
    {
        public uint cbStruct;
        public IntPtr pPolicyCallbackData;
        public IntPtr pSIPClientData;
        public uint dwUIChoice;
        public uint fdwRevocationChecks;
        public uint dwUnionChoice;
        public IntPtr pFile;
        public uint dwStateAction;
        public IntPtr hWVTStateData;
        public IntPtr pwszURLReference;
        public uint dwProvFlags;
        public uint dwUIContext;
        public IntPtr pSignatureSettings;
    }

    [DllImport("wintrust.dll", ExactSpelling = true, CharSet = CharSet.Unicode)]
    static extern uint WinVerifyTrust(IntPtr hwnd, ref Guid pgActionID, ref WINTRUST_DATA pWVTData);

    /// 0 = signed and trusted; TrustNoSignature = unsigned; anything else = a
    /// signature is present but does not verify. Returns "invalid" on any error
    /// so callers fail closed.
    public static uint Verify(string path)
    {
        IntPtr pFile = IntPtr.Zero;
        try
        {
            var fileInfo = new WINTRUST_FILE_INFO
            {
                cbStruct = (uint)Marshal.SizeOf<WINTRUST_FILE_INFO>(),
                pcwszFilePath = path,
            };
            pFile = Marshal.AllocHGlobal(Marshal.SizeOf<WINTRUST_FILE_INFO>());
            Marshal.StructureToPtr(fileInfo, pFile, false);

            var data = new WINTRUST_DATA
            {
                cbStruct = (uint)Marshal.SizeOf<WINTRUST_DATA>(),
                dwUIChoice = WTD_UI_NONE,
                fdwRevocationChecks = WTD_REVOKE_NONE,
                dwUnionChoice = WTD_CHOICE_FILE,
                pFile = pFile,
                dwStateAction = WTD_STATEACTION_VERIFY,
            };
            var guid = GenericVerifyV2;
            uint result = WinVerifyTrust(IntPtr.Zero, ref guid, ref data);

            data.dwStateAction = WTD_STATEACTION_CLOSE;
            WinVerifyTrust(IntPtr.Zero, ref guid, ref data);
            return result;
        }
        catch
        {
            return 0xFFFFFFFF; // treat any failure as "invalid" → caller refuses
        }
        finally
        {
            if (pFile != IntPtr.Zero)
            {
                // frees the marshaled LPWStr the struct owns, then the block
                Marshal.DestroyStructure<WINTRUST_FILE_INFO>(pFile);
                Marshal.FreeHGlobal(pFile);
            }
        }
    }
}
