// DailyTasks.exe - launcher for "משימות יומיות".
// Runs DailyTasks.ps1 IN-PROCESS through a PowerShell runspace on an STA thread,
// so no powershell.exe child process is spawned and no -ExecutionPolicy flag is
// ever used (which antivirus products flag as a dropper pattern).
// If the app is already running, signals it to bring its window forward and exits.
using System;
using System.IO;
using System.Threading;
using System.Reflection;
using System.Management.Automation;
using System.Management.Automation.Runspaces;

[assembly: AssemblyTitle("משימות יומיות")]
[assembly: AssemblyProduct("משימות יומיות")]
[assembly: AssemblyCompany("Lev-Good")]
[assembly: AssemblyDescription("Daily tasks reminder app for Windows")]
[assembly: AssemblyVersion("1.4.1.0")]
[assembly: AssemblyFileVersion("1.4.1.0")]
[assembly: AssemblyInformationalVersion("1.4.1")]

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

        Thread t = new Thread(RunScript);
        t.SetApartmentState(ApartmentState.STA);
        t.Start(script);
        t.Join();
        return 0;
    }

    static void RunScript(object state)
    {
        string script = (string)state;
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
                    ps.AddScript("& '" + script.Replace("'", "''") + "'");
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
