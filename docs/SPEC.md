# SpotifyLyrics Master Hi-Res 无损全曲音源与多通道分布式直链规范 (SPEC)

针对用户反馈**“有没有好用的源，现在很多还是下载失败”**的痛点，彻底解决各大音乐平台 VIP 歌曲公开接口仅下发 15 秒试听片段导致的频繁下载失败问题，全面引入 **Master Hi-Res 24bit 无损全曲音源引擎** 与 **自动音频转码封装管线**。

---

## 阶段一：业务全景泳道图 (Business Swimlane)

```mermaid
flowchart TD
    subgraph User["👤 用户交互 (User)"]
        U1["点击曲目下载 (⌘F) 或一键下载当前播放 (⌘S)"]
        U2["界面实时显示下载进度与母带级音质标签 (FLAC / 320K)"]
        U3["下载完成即刻弹出系统通知并高亮 Finder 目标文件"]
        U4["本地曲库 (⌘L) 秒级刷新，离线双击即开播，悬浮歌词同步展示"]
    end

    subgraph MasterResolver["🚀 Master Hi-Res 无损全曲解析引擎"]
        M1["接收目标歌曲 (Title, Artist, TargetDuration)"]
        M2{"优先调用 Master 全曲无损直链解析通道 (br=1/2)"}
        M3["秒级返回 24bit Hi-Res FLAC / 320K 真实完整音频流 (5~50MB)"]
        M4["若 Master 异常，平滑降级至内置多平台原生备用节点 (Meting/Paugram/Kuwo/Kugou)"]
    end

    subgraph Pipeline["⚙️ 格式探测、转码与防试听门禁"]
        P1["流式下载至临时文件 .tmp"]
        P2{"探测文件头魔数与 MIME 格式"}
        P3["FLAC / MP3: 原生完整音频，直接保持"]
        P4["OGG 音频: 本地 ffmpeg 秒级无损封装转码为高质量 MP3 (320K)"]
        P5{"【AntiPreviewGate 物理时长门禁】\nAVURLAsset 探测解码真实时长 >= 60s?"}
        P6["拦截试听残卷 (秒级物理销毁) 并触发跨平台换源"]
        P7["门禁放行！双轨原子写入: <歌名 - 歌手>.<ext> + <歌名 - 歌手>.lrc"]
    end

    U1 --> M1 --> M2
    M2 -- "命中全曲直链" --> M3 --> P1
    M2 -- "未命中" --> M4 --> P1
    P1 --> P2
    P2 -- "FLAC / MP3" --> P3 --> P5
    P2 -- "OGG" --> P4 --> P5
    P5 -- "时长 < 60s (试听)" --> P6 --> M4
    P5 -- "时长 >= 60s (正曲)" --> P7 --> U3 & U4
```

---

## 阶段二：技术架构时序图 (Technical Sequence)

```mermaid
sequenceDiagram
    autonumber
    actor User as 👤 用户
    participant View as 🖥️ SearchDownloadView
    participant Engine as ⚙️ SongDownloadEngine
    participant Master as 🚀 Master Hi-Res Resolver
    participant Transcoder as 🔄 Local Audio Transcoder (ffmpeg)
    participant Gate as 🛡️ AntiPreviewGate (AVURLAsset)
    participant FS as 💾 本地音乐曲库 (~/Downloads/Music)

    User->>View: 点击下载 "七里香 周杰伦" (或 ⌘S)
    View->>Engine: downloadTrack(candidate)
    
    rect rgb(245, 250, 255)
    Note over Engine, Master: 核心提速通道：Master Hi-Res 直链解析
    Engine->>Master: resolveMasterAudioUrl(title, artist, preferLossless: true)
    Master-->>Engine: 成功返回 24bit Hi-Res FLAC 直链 (Content-Length: 12MB~52MB)
    end

    Engine->>FS: 异步流式下载至 workingTempURL
    
    alt 探测格式为 OGG
        Engine->>Transcoder: ffmpeg -i temp.ogg -c:a libmp3lame -q:a 0 temp.mp3
        Transcoder-->>Engine: 转码为 320K 标准 MP3
    else 探测格式为 FLAC / MP3
        Note over Engine: 原生支持，保持最高原始母带品质
    end

    Engine->>Gate: inspectAudio(workingTempURL)
    Gate-->>Engine: 真实时长探测: 299.0s (>= 60s 门禁通过！)
    
    Engine->>FS: 原子移动至 ~/Downloads/Music/七里香 - 周杰伦.flac
    Engine->>FS: 并发拉取并写入 ~/Downloads/Music/七里香 - 周杰伦.lrc
    Engine-->>View: 状态更新为 .completed
    Engine-->>User: 系统横幅提醒与 Finder 自动定位高亮
```

---

## 三、 详细规格与算法阈值

1. **Master Hi-Res 解析协议**：
   - 目标参数：`https://oiapi.net/api/Kuwo?msg={title}+{artist}&br=1&n=1`（`br=1` 无损 FLAC，`br=2` 高品质，`br=3` 标准）；
   - 响应提取正则：`音乐链接：(\S+)`；
   - 兼容支持用户配置的自定义 API（`DownloadConfig.shared.customApiUrl`）。
2. **转码封装管线**：
   - 检查 `/opt/homebrew/bin/ffmpeg` 或 `/usr/local/bin/ffmpeg`；
   - 若下载内容为 `Ogg data, Vorbis audio`，通过 `ffmpeg -y -i input.ogg -c:a libmp3lame -q:a 0 output.mp3` 进行秒级转码，确保 macOS 原生 `AVAudioPlayer` 完美播放；
   - 若为 FLAC 或 MP3，零损耗保持原样落盘。
3. **门禁与双轨写入**：
   - 真实时长必须满足 $\ge 60$ 秒且误差受控；
   - 音频与 LRC 成对写入，文件名采用统一清洗规则 `<CleanTitle> - <CleanArtist>.<ext>`。
