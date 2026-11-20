# 开发环境：Windows 11 开发 VM + 测试 VM

## 拓扑

    ┌──────────────────────────────┐
    │ 开发 VM（Windows 11）         │
    │  DSH + Git Bash              │
    │  VS 2026 + WDK + SDK         │
    │  WinDbg                      │
    │  源码 C:\svgpu\src           │
    └──────────────┬───────────────┘
                   │ SSH（同一 libvirt 网络）
    ┌──────────────▼───────────────┐
    │ 测试 VM（Windows 11）         │
    │  虚拟 GPU + test signing     │
    │  sshd（内置 Administrator）   │
    │  C:\svgpu\{in,tools,logs}    │
    └──────────────────────────────┘

开发 VM 同时是构建机和控制机；不需要把 VM 暴露给 Linux 沙箱，也不需要 RDP。

## 开发 VM 安装清单

1. Node.js 24（DSH 依赖）
2. Git for Windows（提供 bash / ssh / git）
3. DSH：
   ~~~powershell
   npm install -g @deepseek-ai/dsh
   ~~~
4. Visual Studio 2026 Community：
   - 工作负载：使用 C++ 的桌面开发
   - 单个组件：Windows Driver Kit 28000.2526
   - 单个组件：Windows SDK 10.0.28000.1（工作负载不会装它）
   - 单个组件：Debugging Tools for Windows（经典 windbg/kd）
   - 可选：MSVC Spectre 缓解库
5. 源码：
   ~~~powershell
   git clone https://git.linuxacme.com/liyepan/SoftwareVirtualGPU.git C:\svgpu\src
   ~~~
6. 在 C:\svgpu\src 里启动 dsh，这样 AGENTS.md 会被加载。

## SSH 密钥

在开发 VM 上生成（Git Bash 或 PowerShell 都行）：

~~~powershell
ssh-keygen -t ed25519 -f $env:USERPROFILE\.ssh\svgpu_test -C dsh-dev
Get-Content $env:USERPROFILE\.ssh\svgpu_test.pub
~~~

把公钥加到测试 VM 的 C:\ProgramData\ssh\administrators_authorized_keys（见下）。
私钥权限收紧：

~~~powershell
icacls $env:USERPROFILE\.ssh\svgpu_test /inheritance:r /grant:r "$env:USERNAME:F"
~~~

测试连通：

~~~powershell
ssh -i $env:USERPROFILE\.ssh\svgpu_test Administrator@<TEST_VM_IP> "whoami /groups | findstr Mandatory"
~~~

期望看到 High Mandatory Level。

## 测试 VM 预配置

管理员 PowerShell：

~~~powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Set-Service sshd -StartupType Automatic
Start-Service sshd
New-NetFirewallRule -Name sshd -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -PropertyType String -Force

$pub = Get-Content C:\path\to\svgpu_test.pub
Add-Content C:\ProgramData\ssh\administrators_authorized_keys $pub
icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F"
~~~

C:\ProgramData\ssh\sshd_config 里设置：

    PasswordAuthentication no
    PubkeyAuthentication yes

重启 sshd。

测试签名与内核调试：

~~~powershell
bcdedit /set testsigning on
bcdedit /set debug on
bcdedit /dbgsettings net hostip:<DEV_VM_IP> port=50000 key=1.2.3.4
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -Name CrashDumpEnabled -Value 7
powercfg /change standby-timeout-ac 0
powercfg /hibernate off
~~~

自动登录（截图需要控制台会话）：

~~~powershell
$p = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty $p AutoAdminLogon 1
Set-ItemProperty $p DefaultUserName 'Administrator'
Set-ItemProperty $p DefaultPassword '<PASSWORD>'
~~~

建目录：

~~~powershell
New-Item -ItemType Directory -Force C:\svgpu\in, C:\svgpu\out, C:\svgpu\tools, C:\svgpu\logs
~~~

## 部署工具脚本到测试 VM

在开发 VM 的 Git Bash 里：

~~~bash
scp C:/svgpu/src/tools/install.ps1 C:/svgpu/src/tools/collect.ps1 C:/svgpu/src/tools/shot.ps1 Administrator@<TEST_VM_IP>:C:/svgpu/tools/
~~~

在测试 VM 上建截图任务：

~~~powershell
schtasks /create /tn Shot /tr "powershell -NoProfile -ExecutionPolicy Bypass -File C:\svgpu\tools\shot.ps1" /sc once /st 00:00 /ru Administrator /it /f
~~~

## 冒烟检查

开发 VM：

~~~bash
node -v
git --version
ssh -V
cmd.exe //c "C:\\svgpu\\src\\tools\\build.bat"
~~~

最后一条预期退出码 2（driver\svgpu.sln 还不存在）。如果报 VS/WDK 找不到，回到安装清单。

测试 VM：

~~~powershell
ssh -i $env:USERPROFILE\.ssh\svgpu_test Administrator@<TEST_VM_IP> "pnputil /enum-devices /class Display"
~~~

## 一次完整循环

1. 开发 VM 上改代码、构建：cmd.exe //c "C:\\svgpu\\src\\tools\\build.bat" Debug
2. 产物 scp 到测试 VM 的 C:\svgpu\in
3. 测试 VM 上 powershell -File C:\svgpu\tools\install.ps1
4. 重启，等 SSH 回来
5. powershell -File C:\svgpu\tools\collect.ps1，把 C:\svgpu\logs\<时间戳>.zip 拉回
6. 需要看画面：schtasks /run /tn Shot，scp C:\svgpu\shot.png

## 排障

- DSH 的 bash 工具报找不到 bash：把 C:\Program Files\Git\bin 加进 PATH，重开终端；
  还不行就退回 WSL2 跑 DSH，用 cmd.exe /c 调 Windows 构建。
- cmd.exe //c 被吃成 C:\：确认是双斜杠，路径加引号。
- scp 远端路径：用 C:/svgpu/... 正斜杠。
- 测试 VM SSH 连不上：先 ping，再看 sshd 服务、防火墙、sshd_config 的 PasswordAuthentication。
- 驱动装完蓝屏：等自动重启，SSH 回来收 C:\Windows\MEMORY.DMP，用 windbg -z 分析。
