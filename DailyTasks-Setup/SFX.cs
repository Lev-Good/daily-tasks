// DailyTasks-Setup.exe - self-extracting installer
// Extracts the embedded payload to %TEMP%\DailyTasksInstall, runs setup.ps1
// via PowerShell, waits for it to finish, then deletes the temp folder.
using System;
using System.IO;
using System.Reflection;
using System.Diagnostics;
using System.Windows.Forms;

class Program
{
    static string[] Files = new string[]
    {
        "DailyTasks.cmd",
        "DailyTasks.ps1",
        "DailyTasks.exe",
        "DailyTasks.ico",
        "install.cmd",
        "uninstall.cmd",
        "uninstall.ps1",
        "README.txt",
        "setup.ps1",
        "sound.wav",
        "success.wav",
        "tasks.json"
    };

    static int Main()
    {
        try
        {
            string dir = Path.Combine(Path.GetTempPath(), "DailyTasksInstall");
            if (Directory.Exists(dir)) Directory.Delete(dir, true);
            Directory.CreateDirectory(dir);

            Assembly asm = Assembly.GetExecutingAssembly();
            foreach (string name in Files)
            {
                Stream res = asm.GetManifestResourceStream(name);
                if (res != null)
                {
                    using (FileStream fs = File.Create(Path.Combine(dir, name)))
                    {
                        res.CopyTo(fs);
                    }
                }
            }

            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = "powershell.exe";
            psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + Path.Combine(dir, "setup.ps1") + "\"";
            psi.WorkingDirectory = dir;
            psi.UseShellExecute = false;
            Process p = Process.Start(psi);
            p.WaitForExit();
            int exitCode = p.ExitCode;

            Directory.Delete(dir, true);
            return exitCode;
        }
        catch (Exception ex)
        {
            string dir = Path.GetTempPath();
            try
            {
                dir = Path.Combine(Path.GetTempPath(), "DailyTasksInstall");
                File.WriteAllText(Path.Combine(dir, "install_error.txt"), ex.ToString());
            }
            catch { }
            MessageBox.Show(
                "ההתקנה נכשלה: " + ex.Message + "\nפרטים נוספים נשמרו ב-" + Path.Combine(dir, "install_error.txt"),
                "משימות יומיות - שגיאה",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return 1;
        }
    }
}
