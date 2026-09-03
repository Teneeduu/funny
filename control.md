这是因为页面将 Markdown 代码直接解析渲染成了网页界面。

为了方便你直接复制，这里把 **“Windows 命令行弹窗与声音控制”** 整理进了可一键复制的代码块中。你直接点击代码框右上角的 **“复制”** 按钮即可：

```markdown
# Windows 命令行弹窗与声音控制指南

> 本指南整理了在 CMD 与 PowerShell 中实现播放声音、TTS 语音合成以及桌面弹窗控制的常用方法，并附带远程 SSH / WinRM 会话中的兼容性说明。

---

## 一、 声音控制与语音合成

### 1. PowerShell 声音播放

* **简易蜂鸣音（Bell 响铃）**
  ```powershell
  # 方法 1：输出 ASCII 响铃符
  Write-Host "`a"

  # 方法 2：自定义频率 (1000Hz) 与持续时间 (500ms)
  [console]::beep(1000, 500)

```

* **系统内置事件音**
```powershell
[System.Media.SystemSounds]::Beep.Play()         # 默认提示音
[System.Media.SystemSounds]::Hand.Play()         # 错误 / 停止提示音
[System.Media.SystemSounds]::Exclamation.Play()  # 感叹号提示音
[System.Media.SystemSounds]::Question.Play()     # 提问提示音

```


* **播放本地 WAV 音频**
```powershell
$player = New-Object System.Media.SoundPlayer("C:\path\to\your\sound.wav")
$player.Play() # 后台播放，不阻塞脚本运行

```



---

### 2. TTS 文字转语音朗读（支持远程 SSH 运行）

利用系统内置的 SAPI 语音引擎将文本朗读出来：

```powershell
Add-Type -AssemblyName System.Speech
$speak = New-Object System.Speech.Synthesis.SpeechSynthesizer
$speak.Speak("任务已完成！")

```

---

## 二、 桌面弹窗命令

### 1. CMD 命令提示符弹窗

* **`msg` 命令（推荐，支持远程 Session 穿透）**
```cmd
msg * "这里是弹窗内容"

```


> **说明**：`*` 代表发送给当前登录这台电脑的所有桌面会话。在远程 SSH/CMD 中运行可穿透到被控端的实际屏幕上。


* **`mshta` 调用 VBScript 弹窗**
```cmd
mshta vbscript:msgbox("这里是弹窗内容",64,"弹窗标题")(window.close)

```


> **图标代号**：`16`=错误(红)，`32`=询问(蓝)，`48`=警告(黄)，`64`=信息(蓝)。



---

### 2. PowerShell 脚本弹窗

* **Wscript.Shell 基础弹窗（仅限本地桌面会话）**
```powershell
(New-Object -ComObject Wscript.Shell).Popup("提示内容", 0, "弹窗标题", 0)

```


* **远程会话穿透桌面弹窗**
```powershell
# 方式 1：直接调用 msg 命令
msg * "远程发送的提示信息"

# 方式 2：使用计划任务穿透 Session 0 隔离
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-Command `"(New-Object -ComObject Wscript.Shell).Popup('任务完成！', 0, '提示', 0)`""
Register-ScheduledTask -TaskName "RemotePopup" -Action $action -User$env:USERNAME -Force
Start-ScheduledTask -TaskName "RemotePopup"
Unregister-ScheduledTask -TaskName "RemotePopup" -Confirm:$false

```



---

## 三、 远程 SSH / WinRM 兼容性速查表

| 功能类型 | 具体命令 | 本地支持 | 远程 SSH/WinRM | 机制 / 原因说明 |
| --- | --- | --- | --- | --- |
| **声音** | `System.Speech (TTS)` |  |  | 依赖后台 AudioSrv 服务，无需 GUI 图形上下文即可触发音频。 |
| **声音** | `[console]::beep()` |  |  | 依赖远程主机物理声卡驱动或音频通道激活状态。 |
| **弹窗** | `msg * "内容"` |  |  | Windows 跨会话消息机制，能够直接穿透到前端桌面用户界面。 |
| **弹窗** | `Wscript.Shell.Popup` |  |  | 受 Session 0 隔离影响，在没有 GUI 绘图环境的后台服务中会被忽略。 |
| **弹窗** | `mshta vbscript:...` |  |  | 依赖桌面窗口管理器 (DWM) 渲染，无桌面上下文时无法弹出。 |

```

```