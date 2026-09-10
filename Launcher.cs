// DailyTasks.exe - launcher for "משימות יומיות".
// Runs DailyTasks.ps1 IN-PROCESS through a PowerShell runspace on an STA thread,
// so no powershell.exe child process is spawned and no -ExecutionPolicy flag is
// ever used (which antivirus products flag as a dropper pattern).
// If the app is already running, signals it to bring its window forward and exits.
using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Reflection;
using System.Management.Automation;
using System.Management.Automation.Runspaces;

[assembly: AssemblyTitle("משימות יומיות")]
[assembly: AssemblyProduct("משימות יומיות")]
[assembly: AssemblyCompany("Lev-Good")]
[assembly: AssemblyDescription("Daily tasks reminder app for Windows")]
[assembly: AssemblyVersion("1.4.9.0")]
[assembly: AssemblyFileVersion("1.4.9.0")]
[assembly: AssemblyInformationalVersion("1.4.9")]

class Program
{
    static int Main()
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(dir, "DailyTasks.ps1");
        if (!File.Exists(script)) return 2;

        // If the app is already running, ask it to show its window and exit.
        try
        {
            using (Mutex m = Mutex.OpenExisting(@"Global\DailyTasksApp_Hebrew"))
            {
                try
                {
                    using (EventWaitHandle ev = EventWaitHandle.OpenExisting(@"Global\DailyTasksApp_Show"))
                        ev.Set();
                }
                catch { }
                return 0;
            }
        }
        catch { }

        // A desktop/Start-menu shortcut or a double-click means the user wants to
        // see the window, so pass --show to the script: the window is always shown
        // on a manual launch even when "start minimized" is enabled. The Startup
        // shortcut passes --autostart instead, so an automatic boot launch still
        // honors the user's "start minimized" setting.
        List<string> scriptArgs = new List<string>();
        string[] cmd = Environment.GetCommandLineArgs();
        for (int i = 1; i < cmd.Length; i++) scriptArgs.Add(cmd[i]);
        if (!scriptArgs.Contains("--show") && !scriptArgs.Contains("--autostart"))
            scriptArgs.Add("--show");

        object[] payload = new object[] { script, string.Join(" ", scriptArgs.ToArray()) };
        Thread t = new Thread(RunScript);
        t.SetApartmentState(ApartmentState.STA);
        t.Start(payload);
        t.Join();
        return 0;
    }

    static void RunScript(object state)
    {
        object[] payload = (object[])state;
        string script = (string)payload[0];
        string extraArgs = (string)payload[1];
        try
        {
            Runspace runspace = RunspaceFactory.CreateRunspace();
            runspace.ApartmentState = ApartmentState.STA; // must be set before Open()
            runspace.Open();
            try
            {
                using (PowerShell ps = PowerShell.Create())
                {
                    ps.Runspace = runspace;
                    ps.AddCommand("Set-Location").AddArgument(Path.GetDirectoryName(script));
                    ps.AddScript("& '" + script.Replace("'", "''") + "' " + extraArgs);
                    ps.Invoke();
                }
            }
            finally
            {
                runspace.Close();
            }
        }
        catch (Exception ex)
        {
            try
            {
                File.AppendAllText(Path.Combine(Path.GetDirectoryName(script), "error.log"),
                    DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " Launcher: " + ex.Message + Environment.NewLine);
            }
            catch { }
        }
    }
}
