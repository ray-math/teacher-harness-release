using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using Microsoft.Win32;

internal sealed class DeliveryConfig {
    public string openProtocol { get; set; }
    public string openTargetManifest { get; set; }
    public string metadataFolderName { get; set; }
    public string humanCabinet { get; set; }
    public string incomingRoot { get; set; }
}

internal sealed class LauncherConfig {
    public string shell { get; set; }
    public string pwsh { get; set; }
    public string handler { get; set; }
}

internal sealed class OpenManifest {
    public List<WorkRegistration> workFolders { get; set; }
}

internal sealed class WorkRegistration {
    public string workFolder { get; set; }
    public string console { get; set; }
    public List<string> targets { get; set; }
}

internal static class HumanWorkOpenLauncher {
    private sealed class Attempt {
        public readonly JavaScriptSerializer Json = new JavaScriptSerializer();
        public readonly List<WorkRegistration> Registrations = new List<WorkRegistration>();
        public readonly string InvocationId = Guid.NewGuid().ToString("N");
        public string Workspace, RequestId = "", Action = "unknown", Stage = "arguments", RouteForm = "unknown";
        public DeliveryConfig Config;
        public bool ValidateOnly, Dispatched, Succeeded, CabinetRuntime;
        public int Code = 1;
        public long DispatchMilliseconds;
        public string ErrorType, AckErrorType;
        public int? NativeErrorCode;
        public int AckWritten;
    }
    private static readonly HashSet<string> AllowedExtensions = new HashSet<string>(StringComparer.OrdinalIgnoreCase) {
        ".hwp", ".hwpx", ".hwt", ".hwtx", ".pdf", ".doc", ".docx",
        ".xls", ".xlsx", ".xlsm", ".odt", ".mp3", ".ppt", ".pptx", ".csv", ".txt",
        ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp",
        ".htm", ".html", ".md", ".zip"
    };

    [STAThread]
    private static int Main(string[] args) {
        return Run(args, Process.Start);
    }

    private static int Run(string[] args, Func<ProcessStartInfo, Process> dispatch) {
        Attempt attempt = new Attempt();
        try {
            attempt.ValidateOnly = args.Length > 0 && String.Equals(args[0], "--validate", StringComparison.OrdinalIgnoreCase);
            // Correlate even malformed requests before reading configuration or manifests.
            foreach (string argument in args) {
                Match id = Regex.Match(argument.Trim().Trim('"'), @"/([a-f0-9]{32})/?$", RegexOptions.IgnoreCase);
                if (id.Success) { attempt.RequestId = id.Groups[1].Value.ToLowerInvariant(); break; }
            }
            string bin = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
            DirectoryInfo workspaceInfo = Directory.GetParent(bin);
            if (workspaceInfo == null || workspaceInfo.Parent == null || workspaceInfo.Parent.Parent == null) return 3;
            attempt.Workspace = workspaceInfo.Parent.Parent.FullName;
            WriteDiagnostic(attempt, "received");
            attempt.Code = Execute(args, attempt, dispatch);
        } catch (Exception error) {
            attempt.ErrorType = error.GetType().FullName;
            System.ComponentModel.Win32Exception native = error as System.ComponentModel.Win32Exception;
            if (native != null) attempt.NativeErrorCode = native.NativeErrorCode;
            attempt.Code = 1;
        } finally {
            if (!attempt.ValidateOnly) {
                foreach (WorkRegistration registration in attempt.Registrations) {
                    try {
                        if (!String.IsNullOrEmpty(attempt.RequestId)) {
                            WriteAcknowledgement(attempt, registration);
                            attempt.AckWritten++;
                        }
                    } catch (Exception error) {
                        attempt.AckErrorType = error.GetType().FullName;
                        if (attempt.Code == 0) attempt.Code = 9;
                    }
                }
                WriteDiagnostic(attempt, "finished");
            }
        }
        return attempt.Code;
    }

    private static int Execute(string[] args, Attempt attempt, Func<ProcessStartInfo, Process> dispatch) {
            bool validateOnly = attempt.ValidateOnly;
            if ((!validateOnly && args.Length != 1) || (validateOnly && args.Length != 2 && args.Length != 3)) return 2;
            string raw = (validateOnly ? args[1] : args[0]).Trim().Trim('"');
            if (String.IsNullOrWhiteSpace(raw)) return 2;
            string workspace = attempt.Workspace;
            JavaScriptSerializer json = attempt.Json;
            attempt.Stage = "configuration";
            DeliveryConfig config = json.Deserialize<DeliveryConfig>(File.ReadAllText(Path.Combine(workspace, ".agent", "index", "delivery-system.json"), Encoding.UTF8));
            if (config == null || String.IsNullOrWhiteSpace(config.openProtocol) || String.IsNullOrWhiteSpace(config.openTargetManifest)) return 3;
            // A browser may retain an older association to the maintenance binary.
            // Resolve its configured cabinet before any manifest lookup, so both
            // executable paths consume the same current registration and handler.
            // Explicit --validate manifest fixtures remain isolated.
            if ((!validateOnly || args.Length == 2) && !String.IsNullOrWhiteSpace(config.humanCabinet)) {
                string cabinet = Path.GetFullPath(config.humanCabinet).TrimEnd(Path.DirectorySeparatorChar);
                if (!String.Equals(cabinet, workspace.TrimEnd(Path.DirectorySeparatorChar), StringComparison.OrdinalIgnoreCase)) {
                    attempt.Stage = "runtime-selection";
                    string cabinetConfig = Path.Combine(cabinet, ".agent", "index", "delivery-system.json");
                    EnsureNoReparsePath(cabinetConfig);
                    if (!File.Exists(cabinetConfig)) return 3;
                    DeliveryConfig installed = json.Deserialize<DeliveryConfig>(File.ReadAllText(cabinetConfig, Encoding.UTF8));
                    if (installed == null || !String.Equals(installed.openProtocol, config.openProtocol, StringComparison.OrdinalIgnoreCase) ||
                        String.IsNullOrWhiteSpace(installed.humanCabinet) ||
                        !String.Equals(Path.GetFullPath(installed.humanCabinet).TrimEnd(Path.DirectorySeparatorChar), cabinet, StringComparison.OrdinalIgnoreCase) ||
                        String.IsNullOrWhiteSpace(installed.openTargetManifest)) return 3;
                    workspace = cabinet;
                    attempt.Workspace = cabinet;
                    attempt.CabinetRuntime = true;
                    config = installed;
                }
            }
            attempt.Config = config;
            attempt.Stage = "uri";
            string prefix = config.openProtocol + ":";
            if (!raw.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) return 4;
            attempt.RouteForm = raw.Substring(prefix.Length).StartsWith("//") ? "authority" : "opaque";
            string route = raw.Substring(prefix.Length).TrimStart('/');
            Match refresh = Regex.Match(route, "^refresh/([A-Za-z0-9_-]+)/([a-f0-9]{32})/?$", RegexOptions.IgnoreCase);
            if (refresh.Success) {
                attempt.Action = "refresh";
                attempt.Stage = "decode";
                string refreshTarget = Path.GetFullPath(DecodeBase64Url(refresh.Groups[1].Value));
                attempt.Stage = "manifest";
                string refreshManifestPath = validateOnly && args.Length == 3 ? Path.GetFullPath(args[2]) : Path.GetFullPath(Path.Combine(workspace, config.openTargetManifest));
                OpenManifest refreshManifest = json.Deserialize<OpenManifest>(File.ReadAllText(refreshManifestPath, Encoding.UTF8));
                bool registeredRefresh = false;
                if (refreshManifest != null && refreshManifest.workFolders != null) {
                    foreach (WorkRegistration work in refreshManifest.workFolders) {
                        if (work != null && !String.IsNullOrWhiteSpace(work.workFolder) && String.Equals(Path.GetFullPath(work.workFolder), refreshTarget, StringComparison.OrdinalIgnoreCase)) {
                            registeredRefresh = true;
                            attempt.Registrations.Add(work);
                            break;
                        }
                    }
                }
                if (!registeredRefresh) return 7;
                if (validateOnly) return 0;
                attempt.Stage = "refresh-handler";
                LauncherConfig launcher = json.Deserialize<LauncherConfig>(File.ReadAllText(Path.Combine(workspace, ".agent", "index", "human-open-launcher.json"), Encoding.UTF8));
                if (launcher == null || String.IsNullOrWhiteSpace(launcher.handler)) return 8;
                attempt.Succeeded = InvokeRefresh(launcher.handler, raw);
                attempt.Stage = attempt.Succeeded ? "refreshed" : "refresh-handler";
                return attempt.Succeeded ? 0 : 1;
            }

            Match open = Regex.Match(route, "^open/([A-Za-z0-9_-]+)(?:/([a-f0-9]{32}))?/?$", RegexOptions.IgnoreCase);
            if (!open.Success) return 5;
            attempt.Action = "open";
            attempt.Stage = "decode";
            string target = Path.GetFullPath(DecodeBase64Url(open.Groups[1].Value));
            attempt.Stage = "manifest";
            string manifestPath = validateOnly && args.Length == 3 ? Path.GetFullPath(args[2]) : Path.GetFullPath(Path.Combine(workspace, config.openTargetManifest));
            OpenManifest manifest = json.Deserialize<OpenManifest>(File.ReadAllText(manifestPath, Encoding.UTF8));
            List<WorkRegistration> registrations = attempt.Registrations;
            if (manifest != null && manifest.workFolders != null) {
                foreach (WorkRegistration work in manifest.workFolders) {
                    if (work == null || work.targets == null) continue;
                    foreach (string registered in work.targets) {
                        if (!String.IsNullOrWhiteSpace(registered) && String.Equals(Path.GetFullPath(registered), target, StringComparison.OrdinalIgnoreCase)) {
                            registrations.Add(work);
                            break;
                        }
                    }
                }
            }
            if (registrations.Count == 0) return 7;
            attempt.Stage = "target-validation";
            if (!File.Exists(target) || !AllowedExtensions.Contains(Path.GetExtension(target))) return 6;
            string visibilityBoundary = GetVisibilityBoundary(target, config, workspace, registrations);
            if (!IsVisibleFilePath(target, config.metadataFolderName, visibilityBoundary)) return 6;
            if (validateOnly) return 0;

            attempt.Stage = "association";
            ProcessStartInfo start;
            string[] fallback = ResolveRegisteredOpenCommand(Path.GetExtension(target));
            if (fallback == null) {
                start = new ProcessStartInfo(target);
                start.UseShellExecute = true;
            } else {
                start = new ProcessStartInfo(fallback[0], fallback[1].Replace("%1", target));
                start.UseShellExecute = true;
                start.WorkingDirectory = Path.GetDirectoryName(target);
            }
            attempt.Stage = "target-revalidation";
            if (!IsVisibleFilePath(target, config.metadataFolderName, visibilityBoundary)) return 6;
            attempt.Stage = "dispatch";
            Stopwatch elapsed = Stopwatch.StartNew();
            try {
                using (Process process = dispatch(start)) {
                    // ShellExecute may return no process (DDE / an existing app).
                    // Neither a process nor its absence proves a document opened.
                    attempt.Dispatched = true;
                    attempt.Succeeded = true;
                }
            } finally { elapsed.Stop(); attempt.DispatchMilliseconds = elapsed.ElapsedMilliseconds; }
            attempt.Stage = "dispatched";
            return 0;
    }

    // Keep PowerShell hosting outside Main's JIT dependency path for file opens.
    private static bool InvokeRefresh(string handler, string raw) {
                // Delegate to the existing PS 5.1 handler in this process. Waiting
                // for the invocation keeps completion and failure acknowledgements
                // tied to the request instead of losing a hidden child process.
                System.Management.Automation.Runspaces.InitialSessionState initial = System.Management.Automation.Runspaces.InitialSessionState.CreateDefault();
                // Equivalent to the existing -ExecutionPolicy Bypass invocation;
                // this setting is scoped to the hosted session, never persisted.
                initial.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
                using (System.Management.Automation.Runspaces.Runspace runspace = System.Management.Automation.Runspaces.RunspaceFactory.CreateRunspace(initial))
                using (System.Management.Automation.PowerShell session = System.Management.Automation.PowerShell.Create()) {
                    runspace.Open();
                    session.Runspace = runspace;
                    session.AddCommand(handler).AddParameter("Uri", raw);
                    session.Invoke();
                    if (session.HadErrors) {
                        foreach (System.Management.Automation.ErrorRecord error in session.Streams.Error) {
                            Console.Error.WriteLine(error.ToString());
                        }
                        return false;
                    }
                }
                return true;
    }

    private static string GetVisibilityBoundary(string target, DeliveryConfig config, string workspace, List<WorkRegistration> registrations) {
        string boundary = null;
        foreach (string candidate in new[] {config.humanCabinet, config.incomingRoot, Path.GetTempPath()}) {
            if (String.IsNullOrWhiteSpace(candidate)) continue;
            string root = Path.GetFullPath(candidate).TrimEnd(Path.DirectorySeparatorChar);
            if (target.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) && (boundary == null || root.Length > boundary.Length)) boundary = root;
        }
        if (boundary != null) return boundary;
        // A validation fixture or a relocated registration can have its own work
        // root. Do not inherit unrelated OS/container attributes above that root.
        foreach (WorkRegistration registration in registrations) {
            if (String.IsNullOrWhiteSpace(registration.workFolder)) continue;
            string root = Path.GetFullPath(registration.workFolder).TrimEnd(Path.DirectorySeparatorChar);
            if (target.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) && (boundary == null || root.Length < boundary.Length)) boundary = root;
        }
        // Explicit external sources use their parent, matching console generation.
        return boundary ?? Path.GetDirectoryName(target);
    }

    private static bool IsVisibleFilePath(string target, string metadataFolderName, string boundary) {
        try {
            string current = Path.GetFullPath(target);
            string root = Path.GetPathRoot(current);
            while (!String.IsNullOrEmpty(current)) {
                FileAttributes attributes = File.GetAttributes(current);
                if ((attributes & FileAttributes.ReparsePoint) != 0) return false;
                // Windows can mark a drive root Hidden/System. It is not a hidden
                // document folder; still reject reparse points at this boundary.
                if (String.Equals(current.TrimEnd(Path.DirectorySeparatorChar), root.TrimEnd(Path.DirectorySeparatorChar), StringComparison.OrdinalIgnoreCase)) break;
                if ((attributes & (FileAttributes.Hidden | FileAttributes.System)) != 0) return false;
                string name = Path.GetFileName(current);
                if (String.Equals(name, ".ai", StringComparison.OrdinalIgnoreCase) ||
                    (!String.IsNullOrWhiteSpace(metadataFolderName) && String.Equals(name, metadataFolderName, StringComparison.OrdinalIgnoreCase))) return false;
                if (String.Equals(current.TrimEnd(Path.DirectorySeparatorChar), boundary.TrimEnd(Path.DirectorySeparatorChar), StringComparison.OrdinalIgnoreCase)) break;
                current = Path.GetDirectoryName(current);
            }
            return true;
        } catch {
            // Missing, inaccessible or changing paths must not remain openable.
            return false;
        }
    }

    // Returns {executable, argumentTemplate} only when the extension has no default
    // association but a program has registered itself under OpenWithProgids. Returns null
    // whenever a normal association exists, so ShellExecute stays the usual path.
    private static string[] ResolveRegisteredOpenCommand(string extension) {
        if (String.IsNullOrWhiteSpace(extension)) return null;
        try {
            using (RegistryKey choice = Registry.CurrentUser.OpenSubKey(
                       @"Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\" + extension + @"\UserChoice")) {
                if (choice != null && !String.IsNullOrWhiteSpace(choice.GetValue("ProgId") as string)) return null;
            }
        } catch { return null; }

        string progId = null;
        foreach (RegistryKey hive in new[] { Registry.CurrentUser.OpenSubKey(@"Software\Classes"), Registry.ClassesRoot }) {
            if (hive == null) continue;
            using (hive)
            using (RegistryKey extensionKey = hive.OpenSubKey(extension)) {
                if (extensionKey == null) continue;
                string defaultProgId = extensionKey.GetValue(null) as string;
                if (!String.IsNullOrWhiteSpace(defaultProgId)) return null;
                if (progId != null) continue;
                using (RegistryKey openWith = extensionKey.OpenSubKey("OpenWithProgids")) {
                    if (openWith == null) continue;
                    foreach (string candidate in openWith.GetValueNames()) {
                        if (!String.IsNullOrWhiteSpace(candidate)) { progId = candidate; break; }
                    }
                }
            }
        }
        if (String.IsNullOrWhiteSpace(progId)) return null;

        string command = null;
        using (RegistryKey commandKey = Registry.ClassesRoot.OpenSubKey(progId + @"\shell\open\command")) {
            if (commandKey != null) command = commandKey.GetValue(null) as string;
        }
        if (String.IsNullOrWhiteSpace(command)) return null;

        string executable;
        string arguments;
        command = command.Trim();
        if (command.StartsWith("\"")) {
            int close = command.IndexOf('"', 1);
            if (close < 0) return null;
            executable = command.Substring(1, close - 1);
            arguments = command.Substring(close + 1).Trim();
        } else {
            int space = command.IndexOf(' ');
            executable = space < 0 ? command : command.Substring(0, space);
            arguments = space < 0 ? String.Empty : command.Substring(space + 1).Trim();
        }
        if (!File.Exists(executable)) return null;
        if (arguments.IndexOf("%1", StringComparison.Ordinal) < 0) arguments = (arguments + " \"%1\"").Trim();
        return new[] { executable, arguments };
    }

    private static string DecodeBase64Url(string payload) {
        string base64 = payload.Replace('-', '+').Replace('_', '/');
        if (base64.Length % 4 == 2) base64 += "==";
        else if (base64.Length % 4 == 3) base64 += "=";
        else if (base64.Length % 4 == 1) throw new FormatException("Invalid base64url payload");
        return new UTF8Encoding(false, true).GetString(Convert.FromBase64String(base64));
    }

    private static Dictionary<string, object> Result(Attempt attempt) {
        Dictionary<string, object> ack = new Dictionary<string, object>();
        ack["schemaVersion"] = "hwpx-native-open-result/v1";
        ack["requestId"] = attempt.RequestId;
        ack["invocationId"] = attempt.InvocationId;
        ack["ok"] = attempt.Succeeded;
        ack["action"] = attempt.Action;
        ack["status"] = attempt.Dispatched ? "dispatched" : (attempt.Succeeded ? "refreshed" : "failed");
        ack["dispatched"] = attempt.Dispatched;
        ack["opened"] = null; // The launcher cannot observe the application's document state.
        ack["stage"] = attempt.Stage;
        ack["exitCode"] = attempt.Code;
        ack["errorType"] = attempt.ErrorType;
        ack["nativeErrorCode"] = attempt.NativeErrorCode;
        ack["dispatchMilliseconds"] = attempt.DispatchMilliseconds;
        ack["cabinetRuntimeResolved"] = attempt.CabinetRuntime;
        ack["timestampUtc"] = DateTime.UtcNow.ToString("o");
        return ack;
    }

    private static void WriteAcknowledgement(Attempt attempt, WorkRegistration registration) {
        if (registration == null || String.IsNullOrWhiteSpace(registration.workFolder)) throw new IOException("Missing registered work folder");
        string work = Path.GetFullPath(registration.workFolder);
        string folder = attempt.Config.metadataFolderName;
        if (String.IsNullOrWhiteSpace(folder) || folder == "." || folder == ".." || folder.IndexOfAny(new[] {'\\', '/', ':'}) >= 0) throw new IOException("Invalid metadata folder");
        // Metadata is intentionally hidden, but may never redirect ACK writes.
        string metadata = Path.Combine(work, folder);
        EnsureNoReparsePath(metadata);
        if (!Directory.Exists(metadata)) throw new DirectoryNotFoundException();
        string action = attempt.Action == "refresh" ? "refresh" : "open";
        string variable = action == "refresh" ? "__hwpxConsoleRefresh" : "__hwpxConsoleOpen";
        string content = "window." + variable + " = " + attempt.Json.Serialize(Result(attempt)) + ";";
        // Keep the existing polling filename; a request-specific copy prevents a
        // concurrent click from destroying the earlier request's diagnostic ACK.
        AtomicWrite(Path.Combine(metadata, "console-" + action + "-" + attempt.RequestId + ".js"), content);
        AtomicWrite(Path.Combine(metadata, "console-" + action + ".js"), content);
    }

    private static void EnsureNoReparsePath(string path) {
        string current = Path.GetFullPath(path);
        while (!String.IsNullOrEmpty(current)) {
            try {
                if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) throw new IOException("Reparse path rejected");
            } catch (FileNotFoundException) { }
              catch (DirectoryNotFoundException) { }
            current = Path.GetDirectoryName(current);
        }
    }

    private static void AtomicWrite(string path, string content) {
        EnsureNoReparsePath(path);
        string temp = Path.Combine(Path.GetDirectoryName(path), ".native-ack-" + Guid.NewGuid().ToString("N") + ".tmp");
        try {
            using (FileStream stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            using (StreamWriter writer = new StreamWriter(stream, new UTF8Encoding(false))) { writer.Write(content); }
            EnsureNoReparsePath(path);
            if (File.Exists(path)) File.Replace(temp, path, null);
            else File.Move(temp, path);
        } finally { if (File.Exists(temp)) File.Delete(temp); }
    }

    private static void WriteDiagnostic(Attempt attempt, string phase) {
        if (attempt.ValidateOnly || String.IsNullOrEmpty(attempt.Workspace)) return;
        try {
            string root = Path.Combine(Path.GetTempPath(), "hwpx-human-open-launcher");
            EnsureNoReparsePath(root);
            Directory.CreateDirectory(root);
            Dictionary<string, object> result = Result(attempt);
            result["phase"] = phase;
            result["routeForm"] = attempt.RouteForm;
            result["ackWritten"] = attempt.AckWritten;
            result["ackErrorType"] = attempt.AckErrorType;
            string id = String.IsNullOrEmpty(attempt.RequestId) ? attempt.InvocationId : attempt.RequestId;
            AtomicWrite(Path.Combine(root, id + ".json"), attempt.Json.Serialize(result));
        } catch (Exception error) {
            // No safe ACK destination is available before trusted registration, or
            // when it is unwritable. Do not write beside an untrusted URI target.
            Console.Error.WriteLine("Native diagnostic unavailable; requestId=" + attempt.RequestId + "; invocationId=" + attempt.InvocationId + "; errorType=" + error.GetType().FullName);
        }
    }
}
