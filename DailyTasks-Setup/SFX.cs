// DailyTasks-Setup.exe - self-extracting installer (pure C#).
// Writes the embedded payload directly into %LOCALAPPDATA%\DailyTasks, backs up the
// previous version, preserves the user's tasks.json, creates Start-menu/Desktop
// shortcuts and launches the app. No PowerShell is spawned and nothing is extracted
// to %TEMP%, so the installer does not look like a script-dropper to antivirus.
//
// Reliability rules:
//   * A running instance is closed first - otherwise its .exe is locked and the
//     update would be skipped silently, leaving the user with a mix of old and new
//     files (historically the cause of "I installed the new version but nothing
//     changed").
//   * Every file that lands on disk is verified by size; failures are named in a
//     dialog and written to install.log instead of being swallowed.
//   * If the app cannot be started, the user is told - never a silent no-op.
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("משימות יומיות")]
[assembly: AssemblyProduct("משימות יומיות")]
[assembly: AssemblyCompany("Lev-Good")]
[assembly: AssemblyDescription("Installer for משימות יומיות")]
[assembly: AssemblyVersion("1.4.12.0")]
[assembly: AssemblyFileVersion("1.4.12.0")]
[assembly: AssemblyInformationalVersion("1.4.12")]

class Program
{
    const string Version = "1.4.12";
    const string AppFolderName = "DailyTasks";
    const string AppExeName = "DailyTasks.exe";

    static readonly MessageBoxOptions Rtl = MessageBoxOptions.RtlReading | MessageBoxOptions.RightAlign;

    static string[] Files = new string[]
    {
        "DailyTasks.cmd",
        "DailyTasks.ps1",
        "DailyTasks.exe",
        "DailyTasks.ico",
        "diagnose.cmd",
        "install.cmd",
        "uninstall.cmd",
        "uninstall.ps1",
        "README.txt",
        "setup.ps1",
        "sound.wav",
        "success.wav"
    };

    static string dest = "";
    static string installLog = "";

    [STAThread]
    static int Main()
    {
        try
        {
            dest = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                AppFolderName);
            Directory.CreateDirectory(dest);
            installLog = Path.Combine(dest, "install.log");
            Log("=== install v" + Version + " -> " + dest);

            // A running copy locks DailyTasks.exe. Close it first so the update
            // really replaces every file (and log it, so it is never invisible again).
            StopRunningApp();

            // Back up the previous version so an interrupted update can be rolled back.
            string oldPs1 = Path.Combine(dest, "DailyTasks.ps1");
            if (File.Exists(oldPs1))
            {
                try { File.Copy(oldPs1, Path.Combine(dest, "DailyTasks.old.ps1"), true); } catch { }
            }

            Assembly asm = Assembly.GetExecutingAssembly();
            string[] failed = ExtractFiles(asm);
            if (failed.Length > 0)
            {
                // One retry: a process may have taken a moment to release its files.
                Thread.Sleep(700);
                Log("retrying " + failed.Length + " file(s) after a short wait");
                failed = ExtractFiles(asm);
            }

            // Never overwrite the user's existing tasks with an empty template.
            string tasks = Path.Combine(dest, "tasks.json");
            if (!File.Exists(tasks)) File.WriteAllText(tasks, "[]");

            CreateShortcuts(dest);

            if (failed.Length > 0)
            {
                Log("FAILED to update: " + string.Join(", ", failed));
                MessageBox.Show(
                    "ההתקנה הושלמה חלקית. הקבצים האלה לא הוחלפו:\n\n" + string.Join("\n", failed)
                    + "\n\nסביר להניח שהתוכנה עדיין רצה ברקע. לחצו על סמל התוכנה במגש המערכת ליד השעון ובחרו \"יציאה\", ואז הריצו את קובץ ההתקנה שוב.",
                    "משימות יומיות - התקנה חלקית",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Warning,
                    MessageBoxDefaultButton.Button1,
                    Rtl);
            }

            // Launch the app, and say so if that fails - the user must never be
            // left wondering whether anything happened.
            string exe = Path.Combine(dest, AppExeName);
            if (!File.Exists(exe))
            {
                Log("ERROR: " + exe + " is missing after install");
                MessageBox.Show(
                    "ההתקנה הושלמה אבל קובץ ההפעלה חסר:\n" + exe,
                    "משימות יומיות - שגיאה", MessageBoxButtons.OK, MessageBoxIcon.Error, MessageBoxDefaultButton.Button1, Rtl);
                return 3;
            }
            try
            {
                Process.Start(new ProcessStartInfo { FileName = exe, WorkingDirectory = dest, UseShellExecute = true });
                Log("launched " + exe);
            }
            catch (Exception startEx)
            {
                Log("ERROR launching the app: " + startEx.GetType().Name + ": " + startEx.Message);
                MessageBox.Show(
                    "ההתקנה הושלמה, אבל הפעלת התוכנה נכשלה:\n\n" + startEx.Message
                    + "\n\nאפשר לנסות לפתוח אותה מקיצור הדרך בשולחן העבודה, ולשלוח לנו את הקובץ:\n"
                    + Path.Combine(dest, "launcher.log"),
                    "משימות יומיות - שגיאה", MessageBoxButtons.OK, MessageBoxIcon.Error, MessageBoxDefaultButton.Button1, Rtl);
                return 4;
            }
            return 0;
        }
        catch (Exception ex)
        {
            try { Log("FATAL: " + ex.GetType().Name + ": " + ex.Message); } catch { }
            MessageBox.Show(
                "ההתקנה נכשלה: " + ex.Message,
                "משימות יומיות - שגיאה",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error,
                MessageBoxDefaultButton.Button1,
                Rtl);
            return 1;
        }
    }

    // Closes only the copy that runs from our own install folder. An instance in a
    // different folder, or one we cannot inspect (another user/session), is left
    // alone on purpose.
    static void StopRunningApp()
    {
        string exe = Path.Combine(dest, AppExeName);
        int self = Process.GetCurrentProcess().Id;
        try
        {
            foreach (Process p in Process.GetProcessesByName("DailyTasks"))
            {
                if (p.Id == self) continue;
                string path = null;
                try { path = p.MainModule.FileName; } catch (Exception ex) { Log("cannot inspect pid " + p.Id + ": " + ex.GetType().Name); }
                if (path == null) { Log("pid " + p.Id + " could not be inspected - leaving it running"); continue; }
                if (!string.Equals(path, exe, StringComparison.OrdinalIgnoreCase)) { Log("pid " + p.Id + " runs from " + path + " - leaving it running"); continue; }
                try
                {
                    Log("closing running instance pid " + p.Id);
                    p.Kill();
                    p.WaitForExit(3000);
                }
                catch (Exception ex) { Log("could not close pid " + p.Id + ": " + ex.Message); }
            }
        }
        catch (Exception ex)
        {
            Log("StopRunningApp failed: " + ex.Message);
        }
    }

    // Writes every payload file and verifies it landed completely (size match).
    static string[] ExtractFiles(Assembly asm)
    {
        System.Collections.Generic.List<string> failed = new System.Collections.Generic.List<string>();
        foreach (string name in Files)
        {
            Stream res = null;
            try { res = asm.GetManifestResourceStream(name); } catch { }
            if (res == null)
            {
                Log("resource missing from the installer: " + name);
                continue;
            }
            using (res)
            {
                string target = Path.Combine(dest, name);
                long expected = res.Length;
                try
                {
                    using (FileStream fs = new FileStream(target, FileMode.Create, FileAccess.Write, FileShare.None))
                    {
                        res.CopyTo(fs);
                    }
                    long actual = new FileInfo(target).Length;
                    if (expected > 0 && actual != expected) failed.Add(name + "  (נכתב " + actual + " מתוך " + expected + " בייטים)");
                }
                catch (Exception ex)
                {
                    Log("could not write " + name + ": " + ex.GetType().Name + ": " + ex.Message);
                    failed.Add(name);
                }
            }
        }
        return failed.ToArray();
    }

    static void CreateShortcuts(string dest)
    {
        string target = Path.Combine(dest, AppExeName);
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
            catch (Exception ex) { Log("shortcut in " + dir + " failed: " + ex.Message); }
        }

        // Diagnostics shortcut (Start menu only): whatever goes wrong, the user can
        // run this and send us one file instead of guessing.
        try
        {
            string diagnose = Path.Combine(dest, "diagnose.cmd");
            if (File.Exists(diagnose))
            {
                Type wsType = Type.GetTypeFromProgID("WScript.Shell");
                if (wsType != null)
                {
                    object ws = Activator.CreateInstance(wsType);
                    object sc = wsType.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, ws,
                        new object[] { Path.Combine(startMenuDir, "בדיקת תקינות.lnk") });
                    Type scType = sc.GetType();
                    scType.InvokeMember("TargetPath", BindingFlags.SetProperty, null, sc, new object[] { diagnose });
                    scType.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, sc, new object[] { dest });
                    scType.InvokeMember("IconLocation", BindingFlags.SetProperty, null, sc, new object[] { "shell32.dll,220" });
                    scType.InvokeMember("Description", BindingFlags.SetProperty, null, sc, new object[] { "בדיקת תקינות והפקת דוח" });
                    scType.InvokeMember("Save", BindingFlags.InvokeMethod, null, sc, null);
                }
            }
        }
        catch (Exception ex) { Log("diagnose shortcut failed: " + ex.Message); }
    }

    static void Log(string message)
    {
        try
        {
            File.AppendAllText(installLog,
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + message + Environment.NewLine,
                new UTF8Encoding(false));
        }
        catch { }
    }
}
