# SoftwareVirtualGPU — 开发机工作区说明

> 给运行在 Windows 11 开发 VM 上的 DSH agent。
> 项目背景见 README.md，环境搭建见 docs/DEV_ENV.md。

## 你在哪

- Windows 11 开发 VM，DSH 的 bash 工具走 Git Bash。
- 仓库根目录：C:\svgpu\src
- 构建产物：C:\svgpu\src\out
- 日志/截图/临时：C:\svgpu\src\artifacts
- 测试 VM：SSH 访问（地址见下），默认 shell 是 PowerShell，管理员权限。

## 当前阶段

M0 是宿主 Linux 侧的虚拟 PCI 设备；Windows 驱动（WDDM KMD + UMD）在 M2 之后。
本机只负责 Windows 驱动；宿主侧代码需要 Linux 环境，不在本机构建。

## 构建

在仓库根目录：

~~~bash
cmd.exe //c "C:\\svgpu\\src\\tools\\build.bat" Debug
~~~

- Git Bash 下必须写 cmd.exe //c（双斜杠），否则 /c 会被 MSYS 当路径转换。
- 路径用双反斜杠或正斜杠，别让 bash 把 \ 吃掉。
- build.bat 用 vswhere 找 VS 2026，调用 VsDevCmd，再 msbuild。
- 还没创建 driver\svgpu.sln，脚本会以退出码 2 提示，这是预期。

## 测试 VM

- SSH：ssh -i ~/.ssh/svgpu_test Administrator@<TEST_VM_IP>
- 管理员：内置 Administrator（RID 500），SSH 会话为高完整性。
- 部署：scp 驱动包到 C:\svgpu\in
- 安装：ssh ... "powershell -NoProfile -ExecutionPolicy Bypass -File C:\svgpu\tools\install.ps1"
- 收日志：ssh ... "powershell -NoProfile -ExecutionPolicy Bypass -File C:\svgpu\tools\collect.ps1"
- 截图：ssh ... "schtasks /run /tn Shot"，再 scp C:\svgpu\shot.png
- 测试 VM 已开 test signing、Secure Boot 关闭、内核调试指向本机（net:port=50000,key=1.2.3.4）。

## 规矩

1. 不在开发 VM 上装软件；需要新工具先问用户。
2. 测试 VM 是一次性的：装驱动前确认有快照，不放个人数据。
3. 不开 RDP：RDP 是另一个 session、另一套显示驱动，看不到虚拟显卡输出，还会踢掉 LG 的 console session。
4. 驱动崩溃会断 SSH：WinDbg 在本机接内核调试，dump 在测试 VM 的 C:\Windows\MEMORY.DMP。
5. 纯 C：KMD/UMD/宿主侧都不引入 C++；UMD 的 COM 接口用 C 手写 vtable。
6. 本机需要管理员的操作（防火墙、证书）先问用户。

## 常见坑

- Git Bash 把 /c 转成 C:\；调用 Windows 程序用 cmd.exe //c 或 powershell.exe -File。
- bash 里写 Windows 路径用 C:/svgpu/... 或 /c/svgpu/...，不要用反斜杠。
- .bat 用 CRLF；仓库有 .gitattributes。
- SSH 私钥权限不对会被拒绝；必要时用 icacls 收紧。
- 测试 VM 重启后 SSH 要等 10–30 秒；用 ssh -o ConnectTimeout=5 轮询。
- dxdiag /t 是异步的，collect.ps1 里等文件出现再打包。

## 第一步

1. 读 README.md 和 docs/DEV_ENV.md。
2. 冒烟：node -v、git --version、ssh -V、cmd.exe //c "C:\\svgpu\\src\\tools\\build.bat"（预期退出码 2）。
3. 确认能 ssh 到测试 VM 并执行 whoami /groups，看是不是 High Mandatory Level。
4. 把测试 VM 的 IP/用户填进本文件，然后等用户指示做驱动骨架。
