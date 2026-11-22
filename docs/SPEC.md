# SpotifyLyrics 本地音乐播放、曲库管理与本地歌词展示规格规范 (SPEC)

本文档定义 SpotifyLyrics 支持**本地音乐文件夹选择**、**本地音频播放引擎 (AVFoundation)**、**本地同名 LRC 歌词自动关联与展示**以及**本地曲库交互窗口**的完整业务泳道与技术实现时序。

---

## 阶段一：业务全景泳道图 (Business Swimlane)

```mermaid
flowchart TD
    subgraph User["👤 用户交互 (User)"]
        A1["入口 1: 快捷键 ⌘O / 菜单选择本地音乐文件夹"]
        A2["入口 2: 快捷键 ⌘L 唤出本地音乐播放列表"]
        A3["在本地曲库列表中选择曲目双击播放"]
        A4["在悬停条或桌面歌词上切歌、暂停或点击歌词跳转进度"]
        A5["查看桌面悬浮歌词实时高亮同步滚动"]
    end

    subgraph UI["🖥 界面表现层 (SwiftUI & Windows)"]
        B1["系统原生 NSOpenPanel 文件夹选择器"]
        B2["轻量毛玻璃本地音乐列表窗口 (LocalMusicWindow)"]
        B3["展示音频文件清单、时长、[LRC] 本地歌词标签与播放指示器"]
        B4["桌面歌词悬浮窗 (LyricFloatingView)"]
        B5["悬停控制条与菜单栏动态同步本地播放状态"]
    end

    subgraph LocalLibrary["📂 本地曲库中枢 (LocalMusicLibrary)"]
        C1["扫描指定目录下的音频文件 (.mp3, .flac, .m4a, .wav)"]
        C2["解析音频 ID3 元数据与文件名 (<歌名> - <歌手>)"]
        C3["检测并绑定同目录下同名 .lrc 歌词文件"]
        C4["管理当前曲库播放列表与持久化选定文件夹"]
    end

    subgraph AudioEngine["🎵 本地播放引擎 (LocalMusicPlayer)"]
        D1["基于 AVFoundation 构建音频流播放控制器"]
        D2["状态管理：播放/暂停/上一首/下一首/Seek/单曲循环/列表循环"]
        D3["高精度时钟 (250ms) 派发 currentTime 与 duration"]
    end

    subgraph LyricSync["🧠 歌词同步中枢 (LyricViewModel)"]
        E1["双模感知：当前为 Spotify 模式还是 Local 本地模式"]
        E2["优先读取本地同名 .lrc 文件并解析为时间戳行数组"]
        E3["若无本地歌词，自动无感触发全网检索拉取并写入本地"]
        E4["驱动 GPU 阻尼平移，点击歌词实时回拨本地音频进度"]
    end

    A1 --> B1 --> C1
    A2 --> B2 --> C3
    C1 --> C2 --> C3 --> B3
    A3 --> D1
    D1 --> D2 --> D3
    D3 --> E1
    C3 --> E2 --> E4 --> B4
    E2 -- "无本地 LRC" --> E3 --> E2
    A4 --> D2
    E4 --> A5
```

---

## 阶段二：技术架构时序图 (Technical Sequence)

```mermaid
sequenceDiagram
    autonumber
    actor User as 👤 用户
    participant View as 🖥 列表窗口 / 桌面歌词
    participant Library as 📂 LocalMusicLibrary
    participant Player as 🎵 LocalMusicPlayer (AVFoundation)
    participant VM as 🧠 LyricViewModel
    participant FS as 💾 本地文件系统 (.mp3 & .lrc)

    User->>View: 按下 ⌘O 或点击“选择本地音乐文件夹...”
    View->>Library: chooseMusicFolder()
    Library->>FS: 调起 NSOpenPanel 选取文件夹
    FS-->>Library: 返回 folderURL (持久化到 UserDefaults)
    Library->>FS: 扫描目录下的 .mp3 / .flac / .m4a
    Library->>FS: 检查同目录是否存在同名 .lrc 文件
    Library-->>View: 刷新本地曲库清单 (展示曲目与 LRC 状态)

    User->>View: 在列表窗口双击曲目 (或按 ⌘L 后播放)
    View->>Player: playTrack(track)
    Player->>FS: 加载音频文件并启动播放
    Player->>VM: 切换当前播放源为 .local (传递 Track 标识)

    rect rgb(240, 248, 255)
    Note over VM, FS: 步骤一：本地歌词优先加载与同步
    alt 本地存在同名 .lrc 文件
        VM->>FS: 读取本地 <歌名 - 歌手>.lrc 文本
        FS-->>VM: 返回歌词原始文本
        VM->>VM: parseLRC 解析为时间戳歌词数组
    else 本地不存在 .lrc 文件
        VM->>VM: 自动触发后台全网歌词检索
        VM->>FS: 将获取到的歌词写入同目录下 <歌名 - 歌手>.lrc
    end
    end

    loop 播放周期 (每 250ms 高精度驱动)
        Player->>VM: 派发 currentTime (秒)
        VM->>VM: 毫秒级对齐当前高亮歌词行 (currentIndex)
        VM-->>View: 驱动桌面悬浮歌词 GPU 平滑滚动
    end

    User->>View: 点击某一行歌词 (seekToLine)
    View->>Player: seek(to: targetTime)
    Player->>Player: 音频瞬间跳转至指定时间点继续播放
```

---

## 三、 详细技术实施方案

### 1. 本地播放引擎 (`LocalMusicPlayer`)
- **音频核心**：采用 macOS 原生 `AVAudioPlayer` / `AVPlayer`；
- **格式支持**：原生解码 `.mp3`、`.flac`、`.m4a`、`.wav`、`.aac`；
- **状态流转**：`isPlaying`、`currentTime`、`duration`、`currentTrackIndex`、循环模式（列表循环/单曲循环）；
- **悬停控制条联动**：当处于本地播放状态时，悬停控制胶囊上的 `⏮ ⏯ ⏭` 与双击单行折叠直接接管本地播放器。

### 2. 本地曲库与歌词自动对齐 (`LocalMusicLibrary`)
- **默认文件夹**：初始自动指向此前下载目录 `~/Downloads/Music`（用户无需重新配置，刚刚下载好的音乐即刻列出可播）；
- **本地同名歌词对齐规则**：
  - 音频路径：`/path/to/Music/晴天 - 周杰伦.mp3`
  - 自动寻找：`/path/to/Music/晴天 - 周杰伦.lrc`
  - 若存在直接读取，0 网络依赖，纯离线秒开；
  - 若缺失，自动后台无感调用 `LyricsEngine` 拉取并保存同名 `.lrc` 文件到同目录下。

### 3. 本地曲库管理窗口 (`LocalMusicWindow`)
- **交互规范**：
  - 快捷键 **`⌘L`** 呼出/隐藏；
  - 尺寸 600 × 520 毛玻璃沉浸设计，支持 `ESC` 退出；
  - 支持即时关键词搜索过滤曲库；
  - 列表项支持双击播放，标记 `[LRC]` 标识；
  - 底部集成播放控制栏（进度条拖拽、上一首、播放/暂停、下一首、音量控制）。
