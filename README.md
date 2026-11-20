# SoftwareVirtualGPU

**软件定义的虚拟 PCIe 显卡 · Software-defined PCIe GPU for KVM/QEMU**

在 Linux 主机上创建一张虚拟 PCIe 显卡，让 Windows 虚拟机像使用独立显卡一样使用宿主 GPU：
客户机侧是配套的 WDDM 驱动，主机侧把图形命令翻译成 Vulkan/OpenGL 调用。项目不依赖 GPU 直通，
显示保留 virtio-gpu 的 Red Hat DOD，画面通过 Looking Glass 转发。

> 状态：设计阶段。仓库目前只有本文档，尚无实现代码；模块与文件名为暂定名。

## 目标

程序跑起来之后，操作路径应当只有三步：

1. 加载宿主侧程序，主机上出现一张虚拟 PCIe 显卡；
2. 在 virt-manager 里打开虚拟机设置，Add Hardware → PCI Host Device，选中这张卡，启动；
3. 进入 Windows 客户机，设备管理器里多出一个没有驱动的显示设备（黄色感叹号）。

之后：

4. 安装配套 WDDM 驱动，客户机里多出一张可用显卡；
5. 这张卡负责 Direct3D 渲染，画面由 Looking Glass 转发到宿主观看。

### 验收标准

| 编号 | 场景 | 期望结果 |
|---|---|---|
| A1 | 宿主 lspci -nn | 出现一张显示控制器，带 BAR 与 MSI-X |
| A2 | virt-manager 添加硬件 | “PCI Host Device”列表里直接出现该设备 |
| A3 | libvirt | 自动生成 PCI 主机设备（hostdev）配置 |
| A4 | Windows 设备管理器 | “显示控制器”未知设备，错误码 28（未安装驱动） |
| A5 | 宿主桌面 | 不受影响，真实 GPU 继续给宿主使用 |
| A6 | 安装驱动后 | 多出一张显卡，D3D 应用可选中它渲染 |
| A7 | Looking Glass | 能捕获并显示该显卡输出的画面 |

## 非目标

- 不做物理 GPU 直通（VFIO of real GPU）；
- 不替代 virtio-gpu / DOD，DOD 保留为安装驱动前和异常时的基础显示；
- 首版不做 CUDA / OpenCL / 视频编解码；
- 首版不支持 Linux 客户机（后续可加 DRM 驱动复用同一设备）；
- 不追求 3A 游戏帧率，目标是桌面流畅 + 轻量 3D。

## 总体架构

     ┌──────────────────────────── Windows guest ────────────────────────────┐
     │                                                                       │
     │   D3D 应用 ──► D3D runtime ──► UMD (svgpu_umd.dll)                    │
     │                                     │ 命令流                          │
     │   WDDM KMD (svgpu.sys) ◄────────────┘                                 │
     │      │  BAR0 寄存器 / 门铃 / MSI-X                                    │
     │      ▼                                                                │
     │   PCIe function（class 0x030000，vendor:device 待定）                  │
     │                                                                       │
     │   桌面 ──► DOD (viogpudo) / 虚拟显示器 ──► Looking Glass host         │
     └──────────────────────────────────┬────────────────────────────────────┘
                                        │ vfio-pci（hostdev）
     ┌──────────────────────────────────▼────────────────────────────────────┐
     │ Linux host                                                            │
     │                                                                       │
     │   svgpu.ko   虚拟 PCI 主机桥 + IOMMU group + VFIO + 中断              │
     │       │ /dev/svgpu                                                    │
     │       ▼                                                               │
     │   svgpud     命令解析 → Vulkan/OpenGL → 真实 GPU                      │
     │       │                                                               │
     │   客户机 RAM（共享 memfd）◄── GPA 偏移 ──► 资源 / 命令 / 纹理         │
     └───────────────────────────────────────────────────────────────────────┘

控制面：客户机驱动 → BAR0 寄存器 / 门铃 → vfio-pci → svgpu.ko → svgpud
数据面：客户机 RAM（共享 memfd）←→ svgpud（按 GPA 偏移直接读写）
显示面：客户机桌面 → Looking Glass host → IVSHMEM → Looking Glass client

### 为什么必须是“宿主 PCI 设备”

virt-manager 的“PCI Host Device”列表不是 QEMU 的设备列表，而是 libvirt 从宿主
/sys/bus/pci/devices 枚举出来的 PCI 设备（还要求设备有 IOMMU group、能绑定 vfio-pci）。
这决定了三件事：

- QEMU 内部设备模型（-device svgpu-pci）不会出现在这个列表里，只能改 XML 的 qemu:commandline，
  不满足“在 virt-manager 里直接添加”；
- vfio-user 设备（QEMU 的 vfio-user-pci）同样不在宿主 PCI 列表里；
- 必须由内核模块在宿主上创建一张“看得见”的 PCI 设备，并给它 IOMMU group 和 VFIO 路径。

Cyborg 的 pci-sim 已经证明这条路可行：它用内核模块创建 fake PCI host bridge、
为设备生成 IOMMU group，并提供 QEMU 可分配的 VFIO 路径（用于测试 SR-IOV 直通流程）。
本项目采用同样的骨架，但把 BAR/中断/后端换成真正的显卡语义。

代价：虚拟 PCI 总线、IOMMU group、VFIO 都不是稳定的外部 API，跨内核版本容易碎；
fake IOMMU 也不是安全边界。这条路线定位为开发/测试用途。

## 组件

### 1. svgpu.ko（宿主内核模块）

- 创建虚拟 PCI 主机桥和一张显卡 function（class 0x030000，vendor/device ID 待定）；
- BAR0：寄存器窗口（版本、能力、ring 地址、门铃），不做 mmap，让 QEMU 走 pread/pwrite，
  从而每次寄存器访问都能被模块捕获；只放控制面，不放批量数据；
- BAR2：VRAM aperture（可选，映射到共享内存）；
- MSI-X：完成/错误中断，通过 eventfd 与 VFIO 对接；
- IOMMU group + VFIO 绑定路径，使 libvirt/virt-manager 能识别并分配；
- 字符设备 /dev/svgpu：守护进程通过 ioctl 注册、收门铃、触发中断。

### 2. svgpud（宿主后端守护进程）

- 事件循环：门铃、fence、超时；
- 解析客户机命令流，维护“客户机资源 ↔ Vulkan/OpenGL 对象”映射；
- 用宿主 GPU 执行渲染；
- 通过共享 memfd 直接读写客户机 RAM（GPA 即文件偏移），避免在软件设备里实现真正的
  IOMMU 地址翻译；
- 回写 fence，通知内核模块触发 MSI-X。

### 3. Windows WDDM 驱动（后续阶段）

- KMD：PnP、BAR 映射、MSI-X、WDDM 2.x、GPU 虚拟地址、residency、fence、TDR；
- VidPN：创建虚拟显示器（EDID），让桌面可以扩展到这张卡；
- UMD：首版 D3D11 子集，把 D3D 调用编码成设备命令流；
- 安装前设备表现为未知显示控制器；安装后多出一张显卡。

### 4. 显示与 Looking Glass

- 安装驱动前：virtio-gpu + viogpudo（DOD）负责显示；
- 安装驱动后：虚拟显卡可创建虚拟显示器，桌面扩展/切换到该显示器；
- 客户机内运行 looking-glass-host，用 DXGI Desktop Duplication 捕获该显示器，
  经 IVSHMEM 传给宿主 looking-glass-client；
- 兼容性兜底：RDP，或让虚拟显卡只做渲染、由 DOD 负责扫描输出。

## 一次绘制的数据流

1. 应用创建 D3D 设备，UMD 建立与 KMD 的上下文；
2. 应用创建资源，KMD 分配客户机显存，UMD 把 allocation 信息写入命令流；
3. 应用录制命令，UMD 编码为设备命令流；
4. UMD 提交，KMD 写 BAR0 门铃；
5. svgpu.ko 捕获 MMIO 写，通过 /dev/svgpu 通知 svgpud；
6. svgpud 从共享内存读命令，翻译为 Vulkan/OpenGL，提交宿主 GPU；
7. GPU 完成，svgpud 回写 fence，通知内核模块；
8. 内核模块触发 MSI-X，KMD 的 ISR/DPC 唤醒 WDDM fence；
9. 画面经虚拟显示器 → Looking Glass → 宿主客户端。

## 里程碑

| 阶段 | 内容 | 验收 |
|---|---|---|
| M0 | 内核模块创建 PCI 设备 + IOMMU group + VFIO；virt-manager 可添加；Windows 显示未知设备 | A1–A4 |
| M1 | BAR0 寄存器读写、门铃、MSI-X、/dev/svgpu 与 svgpud 握手 | 客户机测试程序能读版本号并收到中断 |
| M2 | WDDM KMD 加载，虚拟显示器点亮，DOD 仍在 | 桌面可扩展到虚拟显示器 |
| M3 | D3D11 子集 + 资源/命令流 + Looking Glass 捕获 | 一个 D3D demo 能渲染并被 LG 看到 |
| M4 | 性能、多 VM、复位/TDR、驱动签名 | 可日常使用 |

## 环境与依赖

- Linux 6.6+（PCI/IOMMU/VFIO API）
- QEMU 8+、libvirt 9+、virt-manager
- Mesa 24+ / Vulkan 1.3（宿主渲染）
- Windows 11 客户机（开发期 test signing）
- virtio-win（DOD 基础显示）
- Looking Glass（host + client）

## 风险与限制

| 风险 | 说明 |
|---|---|
| 虚拟 PCI/IOMMU/VFIO 的稳定性 | 依赖内核内部 API，升级可能失效；fake IOMMU 不是安全边界 |
| MMIO trap 性能 | 每次寄存器访问一次 syscall，控制面必须保持精简 |
| WDDM 驱动工作量 | KMD + UMD 是项目最大的部分，D3D11 子集也不小 |
| Looking Glass 兼容性 | 新虚拟显示器能否被 DXGI duplication 捕获需要实测 |
| 驱动签名 | 开发期 test signing；发布需要 EV 证书与签名流程 |
| 安全边界 | 仅建议在开发/测试环境使用，不要当作隔离边界 |

## 参考

- Cyborg pci-sim：fake PCI host bridge + IOMMU group + VFIO 的测试实现
  https://docs.openstack.org/cyborg/latest/contributor/pci-sim/developer-guide.html
- QEMU vfio-user：用户态 PCI 设备方案
  https://qemu-project.gitlab.io/qemu/system/devices/vfio-user.html
- rocJITsu：用 vfio-user 模拟 AMD GPU 的实践
  https://github.com/ROCm/rocm-systems/tree/main/emulation/rocjitsu
- virtio-win / viogpudo：Windows DOD 驱动
  https://github.com/virtio-win/kvm-guest-drivers-windows
- Looking Glass
  https://looking-glass.io

## License

TBD
