using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Windows.Forms;

// Endfield direct launcher (windowless stub)
//
//  1) 若带附加参数，写入 Start-Endfield.args（计划任务无法直接传参）
//  2) 隐藏执行 schtasks /run /tn EndfieldDirectLaunch 触发最高权限计划任务（免 UAC 模式）
//  3) 计划任务不存在（或安装为 UAC 模式）时，回退到 Start-Endfield.ps1（会弹一次 UAC）
//
// 目标是 /target:winexe，所以双击不会出现控制台窗口。
static class EndfieldLauncher
{
    const string TaskName = "EndfieldDirectLaunch";

    [STAThread]
    static int Main(string[] args)
    {
        string baseDir = AppDomain.CurrentDomain.BaseDirectory;
        try
        {
            // 附加参数中转（无 UAC 计划任务不接受参数）
            string argsFile = Path.Combine(baseDir, "Start-Endfield.args");
            if (args.Length > 0)
            {
                File.WriteAllText(argsFile, string.Join(" ", args), new UTF8Encoding(false));
            }
            else if (File.Exists(argsFile))
            {
                File.Delete(argsFile);
            }

            // 1) 计划任务（免 UAC）
            if (RunSchtasks("/run /tn \"" + TaskName + "\"") == 0) return 0;

            // 2) 回退：直接跑脚本（脚本内部会请求一次 UAC）
            string ps1 = Path.Combine(baseDir, "Start-Endfield.ps1");
            if (File.Exists(ps1))
            {
                var psi = new ProcessStartInfo("powershell.exe",
                    "-NoProfile -ExecutionPolicy Bypass -File \"" + ps1 + "\"")
                {
                    UseShellExecute = true,
                    WorkingDirectory = baseDir
                };
                Process.Start(psi);
                return 0;
            }

            MessageBox.Show(
                "找不到计划任务 " + TaskName + "，也找不到 Start-Endfield.ps1。\r\n请先运行 install.ps1 完成安装。",
                "Endfield direct launcher", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return 1;
        }
        catch (Exception ex)
        {
            MessageBox.Show("启动失败：" + ex.Message, "Endfield direct launcher",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    static int RunSchtasks(string arguments)
    {
        var psi = new ProcessStartInfo("schtasks.exe", arguments)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden
        };
        using (Process p = Process.Start(psi))
        {
            if (p == null) return -1;
            if (!p.WaitForExit(20000)) return -1;
            return p.ExitCode;
        }
    }
}
