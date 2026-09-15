// DailyTasks.exe - launcher for "משימות יומיות".
// Runs DailyTasks.ps1 IN-PROCESS through a PowerShell runspace on an STA thread,
// so no powershell.exe child process is spawned and no -ExecutionPolicy flag is
// ever used (which antivirus products flag as a dropper pattern).
//
// Reliability rules (learned the hard way - users reported "installed but nothing
// happens, not even in the taskbar"):
//   1. Never exit silently. Every step is logged to %LOCALAPPDATA%\DailyTasks\launcher.log.
//   2. If the app is already running, wait for it to ACKNOWLEDGE the show request.
//      No acknowledgement means the running instance is stale/hung or an older
//      build that cannot show itself - offer the user a clean restart.
//   3. Windows PowerShell 5.1 (System.Management.Automation) is required. If it is
//      missing or broken, say so in plain Hebrew instead of vanishing.
//   4. Script errors are captured from the PowerShell error stream and shown, not
//      swallowed by the runspace.
using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Text;
using System.Windows.Forms;

[assembly: System.Reflection.AssemblyTitle("משימות יומיות")]
[assembly: System.Reflection.AssemblyProduct("משימות יומיות")]
[assembly: System.Reflection.AssemblyCompany("Lev-Good")]
[assembly: System.Reflection.AssemblyDescription("Daily tasks reminder app for Windows")]
[assembly: System.Reflection.AssemblyVersion("1.4.10.0")]
[assembly: System.Reflection.AssemblyFileVersion("1.4.10.0")]
[assembly: System.Reflection.AssemblyInformationalVersion("1.4.10")]

class Program
{
    const string Version = "1.4.10";
    const string MutexName = @"Global\DailyTasksApp_Hebrew";
    const string ShowEventName = @"Global\DailyTasksApp_Show";
    const string AckEventName = @"Global\DailyTasksApp_ShowAck";
    const string AppFolderName = "DailyTasks";
    const string AppExeName = "DailyTasks.exe";

    static string appDir = "";
    static string dataDir = "";
    static string logPath = "";
    static int exitCode = 0;
    static string firstError = null;
    static readonly object logLock = new object();

    const MessageBoxOptions Rtl = MessageBoxOptions.RtlReading | MessageBoxOptions.RightAlign;

    [STAThread]
    static int Main()
    {
        appDir = AppDomain.CurrentDomain.BaseDirectory;
        dataDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), AppFolderName);
        logPath = Path.Combine(Directory.Exists(dataDir) ? dataDir : appDir, "launcher.log");

        string script = Path.Combine(appDir, "DailyTasks.ps1");
        Log("=== start v" + Version + " pid=" + System.Diagnostics.Process.GetCurrentProcess().Id +
            " dir=" + appDir + " args=[" + string.Join(" ", Environment.GetCommandLineArgs()) + "]");

        if (!File.Exists(script))
        {
            Fail("קובץ התוכנה חסר:\n" + script);
            return 2;
        }

        // 1) Another instance? Ask it to show its window and make sure it answers.
        try
        {
            using (Mutex probe = Mutex.OpenExisting(MutexName))
            {
                Log("another instance is running (mutex present)");
                if (SignalShowAndWaitForAck())
                {
                    Log("running instance acknowledged - window should be visible, exiting");
                    return 0;
                }

                Log("no acknowledgement from the running instance (stale, hung or old build)");
                DialogResult answer = MessageBox.Show(
                    "משימות יומיות כבר רצה ברקע אבל החלון שלה לא נפתח, כנראה שהיא נתקעה.\n\nלסגור אותה ולפתוח מחדש?",
                    "משימות יומיות",
                    MessageBoxButtons.YesNo,
                    MessageBoxIcon.Warning,
                    MessageBoxDefaultButton.Button1,
                    Rtl);
                if (answer != DialogResult.Yes)
                {
                    Log("user declined the restart");
                    return 0;
                }

                StopRunningInstances();
                if (!WaitForInstanceExit(5000))
                {
                    Fail("התוכנה הקודמת עדיין רצה ואינה מגיבה, ולכן אי אפשר לפתוח אותה מחדש.\n\n"
                       + "פתחו את מנהל המשימות, סיימו את DailyTasks.exe ונסו שוב.");
                    return 4;
                }
                Log("stale instance is gone - starting a fresh one");
            }
        }
        catch (Exception ex)
        {
            Log("no other instance (" + ex.GetType().Name + ")");
        }

        // 2) The app needs Windows PowerShell 5.1 - check before doing anything else.
        if (!PowerShellAvailable())
        {
            Log("System.Management.Automation (Windows PowerShell 5.1) is NOT available");
            Fail("משימות יומיות זקוקה ל-Windows PowerShell 5.1, והוא חסר או פגום במחשב הזה.\n\n"
               + "איך מתקינים:\n"
               + "• Windows 11: הגדרות > מערכת > תכונות אופציונליות > הוספת תכונה > חפשו PowerShell\n"
               + "  והתקינו \"Windows PowerShell 5.1\".\n"
               + "• או הורידו והתקינו Windows Management Framework 5.1 מאתר מיקרוסופט.\n\n"
               + "אחרי ההתקנה לחצו שוב על קיצור הדרך של התוכנה.");
            return 3;
        }

        // 3) Run the app in-process on an STA thread.
        List<string> scriptArgs = new List<string>();
        string[] cmd = Environment.GetCommandLineArgs();
        for (int i = 1; i < cmd.Length; i++) scriptArgs.Add(cmd[i]);
        if (!scriptArgs.Contains("--show") && !scriptArgs.Contains("--autostart"))
            scriptArgs.Add("--show");

        long logOffset = ScriptLogLength();
        DateTime started = DateTime.Now;
        object[] payload = new object[] { script, string.Join(" ", scriptArgs.ToArray()) };
        Thread t = new Thread(RunScript);
        t.SetApartmentState(ApartmentState.STA);
        t.Start(payload);
        t.Join();
        double seconds = (DateTime.Now - started).TotalSeconds;

        // 4) Did the app really come up? If it bailed out instantly and the script
        //    never reported a ready window, the user would see nothing at all.
        bool reachedWindow = ScriptLogSince(logOffset).IndexOf("boot: window ready") >= 0;
        if (firstError != null)
        {
            Log("app reported errors - showing them to the user");
            Fail("התוכנה נתקלה בשגיאה:\n\n" + firstError);
            return 1;
        }
        if (seconds < 10 && !reachedWindow)
        {
            Log("app exited after " + seconds.ToString("0.0") + "s without reporting a ready window");
            Fail("משימות יומיות לא הצליחה להציג חלון. היא נסגרה מיד אחרי הפתיחה.\n\n"
               + "פרטים מלאים בקובץ:\n" + Path.Combine(appDir, "error.log"));
            return 5;
        }

        Log("app session ended normally after " + seconds.ToString("0") + "s");
        return exitCode;
    }

    // Asks the running instance to show its window and waits for its acknowledgement.
    static bool SignalShowAndWaitForAck()
    {
        try
        {
            using (EventWaitHandle ack = new EventWaitHandle(false, EventResetMode.AutoReset, AckEventName))
            using (EventWaitHandle show = EventWaitHandle.OpenExisting(ShowEventName))
            {
                ack.Reset();
                show.Set();
                bool ok = ack.WaitOne(3000);
                Log(ok ? "ACK received" : "ACK timeout after 3000ms");
                return ok;
            }
        }
        catch (Exception ex)
        {
            Log("show signal failed: " + ex.GetType().Name + ": " + ex.Message);
            return false;
        }
    }

    // Kills DailyTasks.exe processes that run from OUR install folder only - an
    // instance from another folder (or another user/session) is left untouched.
    static void StopRunningInstances()
    {
        string exe = Path.Combine(appDir, AppExeName);
        int self = System.Diagnostics.Process.GetCurrentProcess().Id;
        try
        {
            foreach (System.Diagnostics.Process p in System.Diagnostics.Process.GetProcessesByName("DailyTasks"))
            {
                if (p.Id == self) continue;
                string path = null;
                try { path = p.MainModule.FileName; } catch (Exception ex) { Log("cannot inspect pid " + p.Id + ": " + ex.GetType().Name); }
                if (path == null)
                {
                    Log("pid " + p.Id + " could not be inspected - leaving it alone");
                    continue;
                }
                if (!string.Equals(path, exe, StringComparison.OrdinalIgnoreCase))
                {
                    Log("pid " + p.Id + " runs from " + path + " - leaving it alone");
                    continue;
                }
                try
                {
                    Log("closing stale instance pid " + p.Id);
                    p.Kill();
                    p.WaitForExit(3000);
                }
                catch (Exception ex)
                {
                    Log("could not close pid " + p.Id + ": " + ex.Message);
                }
            }
        }
        catch (Exception ex)
        {
            Log("StopRunningInstances failed: " + ex.Message);
        }
    }

    // Waits until nobody holds the single-instance mutex any more.
    static bool WaitForInstanceExit(int milliseconds)
    {
        int waited = 0;
        while (waited < milliseconds)
        {
            try
            {
                using (Mutex m = Mutex.OpenExisting(MutexName))
                {
                    if (m.WaitOne(0, false)) { m.ReleaseMutex(); return true; }
                }
            }
            catch (WaitHandleCannotBeOpenedException)
            {
                return true; // nobody is holding it
            }
            catch { return true; }
            Thread.Sleep(250);
            waited += 250;
        }
        return false;
    }

    // Windows PowerShell 5.1 ships with Windows; it can be removed on Windows 11.
    // Without System.Management.Automation the in-process runspace cannot start.
    static bool PowerShellAvailable()
    {
        try
        {
            string psExe = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System),
                "WindowsPowerShell", "v1.0", "powershell.exe");
            if (!File.Exists(psExe))
            {
                Log("powershell.exe not found at " + psExe);
                return false;
            }
            System.Reflection.Assembly.Load(
                "System.Management.Automation, Version=3.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35");
            return true;
        }
        catch (Exception ex)
        {
            Log("PowerShell availability check failed: " + ex.GetType().Name + ": " + ex.Message);
            return false;
        }
    }

    static void RunScript(object state)
    {
        object[] payload = (object[])state;
        string script = (string)payload[0];
        string extraArgs = (string)payload[1];
        Runspace runspace = null;
        try
        {
            runspace = RunspaceFactory.CreateRunspace();
            runspace.ApartmentState = ApartmentState.STA; // must be set before Open()
            runspace.Open();
            using (PowerShell ps = PowerShell.Create())
            {
                ps.Runspace = runspace;
                ps.AddCommand("Set-Location").AddArgument(Path.GetDirectoryName(script));
                ps.AddScript("& '" + script.Replace("'", "''") + "' " + extraArgs);
                try
                {
                    ps.Invoke();
                }
                catch (Exception ex)
                {
                    firstError = ex.Message;
                    Log("script invocation threw: " + ex.GetType().Name + ": " + ex.Message);
                }

                // Errors written by the script used to disappear completely here.
                if (ps.HadErrors)
                {
                    foreach (ErrorRecord er in ps.Streams.Error)
                    {
                        string text = er.ToString();
                        Log("script error: " + text);
                        if (firstError == null) firstError = text;
                    }
                }
                if (ps.InvocationStateInfo != null && ps.InvocationStateInfo.Reason != null)
                {
                    Log("script state reason: " + ps.InvocationStateInfo.Reason.Message);
                    if (firstError == null) firstError = ps.InvocationStateInfo.Reason.Message;
                }
            }
        }
        catch (Exception ex)
        {
            exitCode = 1;
            firstError = ex.Message;
            Log("launcher exception: " + ex.GetType().Name + ": " + ex.Message);
        }
        finally
        {
            try { if (runspace != null) runspace.Close(); } catch { }
        }
    }

    // The app's own log tells us whether THIS run really got a window up - only the
    // bytes written since the run started count (an older session's lines must not
    // make a failing launch look healthy).
    static long ScriptLogLength()
    {
        try
        {
            FileInfo fi = new FileInfo(Path.Combine(appDir, "error.log"));
            return fi.Exists ? fi.Length : 0;
        }
        catch { return 0; }
    }

    static string ScriptLogSince(long from)
    {
        try
        {
            string p = Path.Combine(appDir, "error.log");
            if (!File.Exists(p)) return "";
            using (FileStream fs = new FileStream(p, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            {
                long start = from <= fs.Length ? from : 0; // the log was trimmed meanwhile
                fs.Seek(start, SeekOrigin.Begin);
                using (StreamReader sr = new StreamReader(fs, Encoding.UTF8))
                    return sr.ReadToEnd();
            }
        }
        catch { return ""; }
    }

    static void Log(string message)
    {
        try
        {
            lock (logLock)
            {
                File.AppendAllText(logPath,
                    DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + message + Environment.NewLine,
                    new UTF8Encoding(false));
                FileInfo fi = new FileInfo(logPath);
                if (fi.Exists && fi.Length > 262144)
                {
                    string[] lines = File.ReadAllLines(logPath, Encoding.UTF8);
                    int keep = lines.Length > 400 ? 400 : lines.Length;
                    string[] tail = new string[keep];
                    Array.Copy(lines, lines.Length - keep, tail, 0, keep);
                    File.WriteAllLines(logPath, tail, new UTF8Encoding(false));
                }
            }
        }
        catch { }
    }

    static void Fail(string message)
    {
        try
        {
            MessageBox.Show(message, "משימות יומיות - שגיאה", MessageBoxButtons.OK, MessageBoxIcon.Error, MessageBoxDefaultButton.Button1, Rtl);
        }
        catch { }
    }
}
