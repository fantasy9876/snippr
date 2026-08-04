using System.Diagnostics;
using System.Net.Http;
using System.Text.Json;

namespace Snippr;

/// Checks the site's version.json; on confirmation downloads the installer
/// (which kills the running copy, installs and can relaunch) and exits.
static class UpdateChecker
{
    const string ManifestUrl = "https://snippr.pages.dev/version.json";

    public static async void Check(bool manual)
    {
        try
        {
            using var http = new HttpClient();
            var json = await http.GetStringAsync(ManifestUrl + "?t=" + Environment.TickCount64);
            using var doc = JsonDocument.Parse(json);
            var remote = doc.RootElement.GetProperty("win").GetString() ?? "0";
            var url = doc.RootElement.GetProperty("winUrl").GetString();
            var current = Application.ProductVersion.Split('+')[0];

            if (url != null && IsNewer(remote, current))
            {
                var answer = MessageBox.Show(
                    $"Snippr {remote} đã có bản mới (bạn đang dùng {current}).\n\n" +
                    "Tải và chạy trình cài đặt ngay? App sẽ tự đóng để cập nhật.",
                    "Snippr Update", MessageBoxButtons.YesNo, MessageBoxIcon.Information);
                if (answer != DialogResult.Yes) return;

                ToastForm.Show("Đang tải bản cập nhật…");
                var tmp = Path.Combine(Path.GetTempPath(), "SnipprSetup-update.exe");
                var bytes = await http.GetByteArrayAsync(url);
                File.WriteAllBytes(tmp, bytes);
                Process.Start(new ProcessStartInfo(tmp) { UseShellExecute = true });
                TrayContext.Instance?.QuitApp();
            }
            else if (manual)
            {
                ToastForm.Show($"Snippr {current} là bản mới nhất ✓");
            }
        }
        catch
        {
            if (manual) ToastForm.Show("Không kiểm tra được bản mới — thử lại sau");
        }
    }

    static bool IsNewer(string a, string b) =>
        Version.TryParse(a, out var va) && Version.TryParse(b, out var vb) && va > vb;
}
