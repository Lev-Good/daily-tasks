// DailyTasks-Setup.exe - self-extracting installer (pure C#).
// Writes the embedded payload directly into %LOCALAPPDATA%\DailyTasks, backs up the
// previous version, preserves the user's tasks.json, creates Start-menu/Desktop
// shortcuts and launches the app. No PowerShell is spawned and nothing is extracted
// to %TEMP%, so the installer does not look like a script-dropper to antivirus.
using System;
using System.IO;
using System.Reflection;
using System.Diagnostics;
using System.Windows.Forms;

[assembly: AssemblyTitle("משימות יומיות")]
[assembly: AssemblyProduct("משימות יומיות")]
[assembly: AssemblyCompany("Lev-Good")]
[assembly: AssemblyDescription("Installer for משימות יומיות")]
[assembly: AssemblyVersion("1.4.1.0")]
[assembly: AssemblyFileVersion("1.4.1.0")]
[assembly: AssemblyInformationalVersion("1.4.1")]

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
        "success.wav"
    };

    static int Main()
    {
        try
        {
            string dest = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "DailyTasks");
            Directory.CreateDirectory(dest);

            // Back up the previous version so an interrupted update can be rolled back.
            string oldPs1 = Path.Combine(dest, "DailyTasks.ps1");
            if (File.Exists(oldPs1))
            {
                try { File.Copy(oldPs1, Path.Combine(dest, "DailyTasks.old.ps1"), true); } catch { }
            }

            Assembly asm = Assembly.GetExecutingAssembly();
            foreach (string name in Files)
            {
                Stream res = asm.GetManifestResourceStream(name);
                if (res == null) continue;
                try
                {
                    using (res)
                    using (FileStream fs = File.Create(Path.Combine(dest, name)))
                    {
                        res.CopyTo(fs);
                    }
                }
                catch { /* file locked (app running): skip; next launch updates it */ }
            }

            // Never overwrite the user's existing tasks with an empty template.
            string tasks = Path.Combine(dest, "tasks.json");
            if (!File.Exists(tasks)) File.WriteAllText(tasks, "[]");

            CreateShortcuts(dest);

            string exe = Path.Combine(dest, "DailyTasks.exe");
            if (File.Exists(exe))
            {
                Process.Start(new ProcessStartInfo { FileName = exe, WorkingDirectory = dest, UseShellExecute = true });
            }
            return 0;
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                "ההתקנה נכשלה: " + ex.Message,
                "משימות יומיות - שגיאה",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return 1;
        }
    }

    static void CreateShortcuts(string dest)
    {
        string target = Path.Combine(dest, "DailyTasks.exe");
        string desktop = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
        string startMenuDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.Programs),
            "משימות יומיות");
        try { Directory.CreateDirectory(startMenuDir); } catch { }

        foreach (string dir in new string[] { desktop, startMenuDir })
        {
            try
            {
                Type wsType = Type.GetTypeFromProgID("WScript.Shell");
                if (wsType == null) continue;
                object ws = Activator.CreateInstance(wsType);
                object sc = wsType.InvokeMember(
                    "CreateShortcut",
                    BindingFlags.InvokeMethod,
                    null,
                    ws,
                    new object[] { Path.Combine(dir, "משימות יומיות.lnk") });
                Type scType = sc.GetType();
                scType.InvokeMember("TargetPath", BindingFlags.SetProperty, null, sc, new object[] { target });
                scType.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, sc, new object[] { dest });
                if (File.Exists(target))
                    scType.InvokeMember("IconLocation", BindingFlags.SetProperty, null, sc, new object[] { target + ",0" });
                scType.InvokeMember("Description", BindingFlags.SetProperty, null, sc, new object[] { "משימות יומיות" });
                scType.InvokeMember("Save", BindingFlags.InvokeMethod, null, sc, null);
            }
            catch { }
        }
    }
}
