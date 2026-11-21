# SpotifyLyrics 音乐搜索、高品质音频与歌词同步下载规格规范 (SPEC)

本文档详细定义 SpotifyLyrics 音乐搜索检索、最高音质音频与同名 LRC 歌词双轨下载、自定义下载目录管理的完整业务泳道与技术架构时序。

---

## 阶段一：业务全景泳道图 (Business Swimlane)

```mermaid
flowchart TD
    subgraph User["👤 用户交互 (User)"]
        A1["入口 1: 快捷键 ⌘S / 右键菜单下载当前歌曲"]
        A2["入口 2: 点击 '搜索并下载音乐' (⌘F) 打开搜索面板"]
        A3["输入关键词 (歌名/歌手) 并点击搜索"]
        A4["在搜索结果列表中点击某首歌曲的 '下载' 按钮"]
        A5["入口 3: 点击 '更改下载目录...' 调起目录选择器"]
        A6["收到完成通知并在 Finder 音乐目录中查收音频与歌词"]
    end

    subgraph UI["🖥 界面表现层 (SwiftUI & NSWindow)"]
        B1["状态栏 / 右键菜单展示当前歌曲下载项"]
        B2["轻量级独立搜索窗口 (SearchDownloadWindow)"]
        B3["展示检索结果列表 (歌名、歌手、专辑、时长、高音质标签)"]
        B4["系统原生 NSOpenPanel 目录选取器"]
        B5["实时下载状态动效 (⏳ 下载音频中... / 抓取歌词中...)"]
    end

    subgraph Controller["🧠 状态与配置中枢 (LyricViewModel & DownloadConfig)"]
        C1["解析当前歌曲元数据 (Title, Artist, Duration)"]
        C2["管理下载目录路径 (默认: ~/Downloads/Music，支持 UserDefaults 持久化)"]
        C3["管理搜索状态、候选列表与下载任务状态映射"]
    end

    subgraph Engine["⚙️ 双轨检索与下载引擎 (SongDownloadEngine)"]
        D1["音频检索：查询开放音源并锁定最高音质 (优先 FLAC / 320Kbps)"]
        D2["歌词检索：调用 LyricsEngine 抓取最佳同步 LRC 歌词文本"]
        D3["双轨流式落盘：安全清洗文件名，写入 <目录>/<歌名 - 歌手>.mp3 与 .lrc"]
        D4["广播 macOS 原生系统通知并高亮唤起 Finder"]
    end

    A1 --> B1 --> C1 --> D1
    A2 --> B2
    A3 --> B2 --> C3 --> D1
    B2 --> B3 --> A4 --> D1
    A5 --> B4 --> C2
    D1 --> D3
    C1 --> D2 --> D3
    D3 --> D4 --> A6
```

---

## 阶段二：技术架构时序图 (Technical Sequence)

```mermaid
sequenceDiagram
    autonumber
    actor User as 👤 用户
    participant View as 🖥 搜索面板 / 浮窗菜单
    participant VM as 🧠 LyricViewModel & Config
    participant Engine as ⚙️ SongDownloadEngine
    participant Netease as 🌐 开放音频解析源 (Netease API)
    participant FS as 💾 本地文件系统 (Music Directory)
    participant MacSystem as 🔔 macOS 系统 (Notification & Finder)

    alt 场景 A：更改下载目录
        User->>View: 点击“更改音乐下载目录...”
        View->>MacSystem: 调起 NSOpenPanel (canChooseDirectories = true)
        MacSystem-->>View: 用户选取新目录 URL
        View->>VM: setDownloadDirectory(url)
        VM->>FS: 校验并确保目录存在 (createDirectoryIfNotExist)
        VM-->>View: 更新菜单与设置回显
    else 场景 B：搜索并下载音乐
        User->>View: 唤出搜索面板 (⌘F)，输入关键词回车
        View->>Engine: searchTracks(keyword)
        Engine->>Netease: 请求检索候选歌曲列表 (GET /cloudsearch)
        Netease-->>Engine: 返回候选结果 (Title, Artist, Album, Duration, Privileges)
        Engine-->>View: 渲染结果列表 (展示 FLAC/320K 最佳音质标识)
        User->>View: 点击目标曲目后的“⬇️ 下载”
        View->>Engine: startDownload(track, customDir)
    else 场景 C：一键下载当前正在播放的曲目
        User->>View: 按下 ⌘S 或点击“下载当前歌曲”
        View->>Engine: startDownload(currentTrack, customDir)
    end

    rect rgb(240, 248, 255)
    Note over Engine, Netease: 步骤一：并发双轨请求 (最高音质音频 + 同步歌词)
    par 音频最高码率探测与直链获取
        Engine->>Netease: 请求播放链接 (level=lossless/exhigh, br=320000)
        Netease-->>Engine: 返回 high_quality_url (FLAC 或 320k MP3)
        Engine->>FS: URLSession.downloadTask 写入 <Dir>/<歌名 - 歌手>.<ext>
    and 歌词抓取与格式化
        Engine->>Netease: 拉取完整高精度 LRC 时间戳歌词
        Netease-->>Engine: 返回 lrc_text
        Engine->>FS: 格式化并写入 <Dir>/<歌名 - 歌手>.lrc
    end
    end

    FS-->>Engine: 音频与歌词双文件落盘完成
    Engine->>MacSystem: 发送系统横幅通知 (“已下载: 歌名 - 歌手 (包含音频与歌词)”)
    Engine->>MacSystem: NSWorkspace.activateFileViewerSelecting([audioURL, lrcURL])
    Engine-->>VM: 更新任务状态为 .completed
    VM-->>View: 界面与搜索结果高亮已下载标识
```

---

## 三、 详细技术方案与规格细节

### 1. 下载目录管理规范
- **默认路径**：`~/Downloads/Music/`（自动创建）；
- **持久化 Key**：`UserDefaults.standard.string(forKey: "UserDownloadDirectory")`；
- **目录校验**：每次启动或修改时自动检查目录是否存在并具备写权限，不存在则自动执行 `createDirectory(at:withIntermediateDirectories:true)`；
- **菜单交互**：
  - `📁 当前保存目录: ~/Downloads/Music`（可点击在 Finder 中打开）；
  - `⚙️ 更改音乐保存目录...`（调起原生文件夹选择器）。

### 2. 最高音质检索与落盘格式
- **音质探测策略**：
  - 检索参数严格优先匹配 `level=lossless`（无损 FLAC）与 `level=exhigh`（320kbps 极高 MP3）；
  - 若解析得到的内容类型为 `audio/flac` 或文件直链后缀为 `.flac`，则自动保存为标准的 `.flac` 扩展名；
  - 若为 MP3 则保存为 `.mp3` 扩展名，绝不进行降采样有损压缩。
- **文件名规范化**：
  - 清洗特殊保留字符（`:`、`/`、`\`、`?`、`*`、`"`、`<`、`>`、`|`）；
  - 统一格式：`<安全歌曲名> - <安全歌手名>.<ext>`。

### 3. 同名 LRC 歌词同步落盘
- 在写入音频文件的同一目录下，同时写入同名歌词文件 `<安全歌曲名> - <安全歌手名>.lrc`；
- 采用 UTF-8 编码，包含 `[ti:]`、`[ar:]`、`[al:]` 以及毫秒级滚动时间戳，能够直接被各类车载播放器、本地播放器（如 IINA、VLC、Foobar2000）完美自动识别加载。

### 4. 独立原生搜索窗口 (Search & Download Window)
- **外观与尺寸**：宽 580px、高 480px 的毛玻璃沉浸式悬浮窗口，按 `ESC` 或关闭按钮可退出；
- **组件结构**：
  - **顶部搜索栏**：输入框自动对齐焦点，支持回车直接触发搜索；
  - **中间列表区**：展示搜索到的前 15~20 首结果，每行展示歌曲名、歌手、专辑、时长、品质标签（如 `320K`、`FLAC`）以及下载操作按钮；
  - **操作状态**：点击后按钮切换为旋转进度圈（`Downloading`），完成后变为绿色对勾（`✓ 已完成`）；
  - **底部状态条**：实时显示当前存储目录，并提供一键更改目录与打开文件夹链接。
