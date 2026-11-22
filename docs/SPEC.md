# SpotifyLyrics 全网四维多源聚合搜索与分布式跨平台直链下载规范 (SPEC)

针对用户反馈**“下载歌曲来源太少，好多都下载不了，甚至搜索不到”**的痛点，全面推行**全网四大主流平台并发聚合搜索**、**多源分布式直链解析**、**跨平台智能自动换源（Cross-Platform Fallback）**与**防试听物理时长门禁**技术方案。

---

## 阶段一：业务全景泳道图 (Business Swimlane)

```mermaid
flowchart TD
    subgraph User["👤 用户交互 (User)"]
        U1["输入关键词搜索 (⌘F) 或一键下载当前播放 (⌘S)"]
        U2["搜索窗口实时呈现聚合结果，带 [网易][酷狗][酷我][QQ] 来源徽标"]
        U3["支持切换顶部平台 Tab：全部 / 网易云 / 酷狗 / 酷我 / QQ音乐"]
        U4["收到下载完成通知，在本地曲库 (⌘L) 离线播放并展示同步歌词"]
        U5["若全网所有源均受限，获得明确、客观的失败提示与原因"]
    end

    subgraph MultiSearch["🌐 四维多源并发检索引擎 (MultiSourceSearchEngine)"]
        S1["接收关键词 (歌名/歌手) 并发派发"]
        S2["源 1: 网易云 (Netease API)"]
        S3["源 2: 酷狗音乐 (Kugou Mobile API)"]
        S4["源 3: 酷我音乐 (Kuwo Search API)"]
        S5["源 4: QQ音乐 (Tencent Smartbox/Search API)"]
        S6["多源结果汇聚、来源标注、去重与三维置信度综合排序"]
    end

    subgraph DownloadPipeline["⚙️ 分布式直链解析与跨平台换源 (MultiSourceDownloadEngine)"]
        D1["优先取出用户点击项或最高分候选曲目"]
        D2{"根据来源分发直链解析通道"}
        D3["网易云通道: Meting 302 / Paugram / 官方 CDN 直链"]
        D4["酷我通道: Antiserver 直链转换 (MP3/FLAC)"]
        D5["酷狗通道: 移动端音频流解析 / 多 CDN 回退"]
        D6["自定义 API 节点: 用户自建解析服务 (若已配置)"]
        D7{"【物理时长门禁 AntiPreviewGate】\nAVURLAsset 探测真实音频时长\n时长 >= 60s 且误差在允许范围?"}
        D8["拦截 VIP 试听残卷 (十几秒)！立即物理删除临时文件"]
        D9{"【跨平台自动换源】\n自动跨源检索其他平台的完整原唱版本"}
        D10["门禁放行！完整音频原子落盘 (~/Downloads/Music)"]
        D11["并发拉取标准 LRC 并写入同名文件，通知曲库"]
    end

    U1 --> S1
    S1 --> S2 & S3 & S4 & S5
    S2 & S3 & S4 & S5 --> S6
    S6 --> U2 & U3
    U1 -.->|⌘S 直接下载| D1
    U2 -->|点击下载| D1
    D1 --> D2
    D2 -->|Netease| D3
    D2 -->|Kuwo| D4
    D2 -->|Kugou| D5
    D2 -->|Custom| D6
    D3 & D4 & D5 & D6 --> D7
    D7 -- "试听残卷 (拦截)" --> D8 --> D9
    D9 -- "找到跨平台候选" --> D1
    D9 -- "全网穷尽无完整源" --> U5
    D7 -- "完整正曲 (通过)" --> D10 --> D11 --> U4
```

---

## 阶段二：技术架构时序图 (Technical Sequence)

```mermaid
sequenceDiagram
    autonumber
    actor User as 👤 用户
    participant View as 🖥️ SearchDownloadView
    participant SearchMgr as 🌐 MultiSourceSearchEngine
    participant Netease as 🔴 网易云源
    participant Kugou as 🔵 酷狗音乐源
    participant Kuwo as 🟡 酷我音乐源
    participant Downloader as ⚙️ MultiSourceDownloadEngine
    participant Gate as 🛡️ AntiPreviewGate (AVURLAsset)
    participant FS as 💾 本地存储 (Music Dir)

    User->>View: 唤出搜索面板并输入 "晴天 周杰伦" (⌘F)
    View->>SearchMgr: searchMultiPlatform(keyword)
    
    par 并发向三大主流开放平台派发搜索请求
        SearchMgr->>Netease: GET music.163.com/api/cloudsearch/pc
        SearchMgr->>Kugou: GET mobilecdn.kugou.com/api/v3/search/song
        SearchMgr->>Kuwo: GET search.kuwo.cn/r.s?client=kt
    and
        Netease-->>SearchMgr: 返回候选集 (可能受版权保护)
        Kugou-->>SearchMgr: 返回原版曲目 (周杰伦原唱、时长 269s)
        Kuwo-->>SearchMgr: 返回原版曲目 (FLAC/320K、时长 269s)
    end

    SearchMgr->>SearchMgr: 结果打标 ([网易] [酷狗] [酷我])，多维评分排序
    SearchMgr-->>View: 渲染全网聚合列表，支持按平台 Tab 过滤

    User->>View: 点击下载某首歌曲 (或当前播放 ⌘S)
    View->>Downloader: downloadTrack(item)

    loop 尝试当前源及跨平台 Fallback 源
        Downloader->>Downloader: 调用对应平台直链解析器
        Downloader->>FS: 下载流至 .downloading 临时文件
        Downloader->>Gate: inspectAudio(tempURL)
        
        alt 时长 < 60s (试听残卷)
            Gate-->>Downloader: 门禁拦截 (15.0s < 60s)
            Downloader->>FS: 物理删除临时文件 (即测即删)
            Downloader->>Downloader: 跨平台自动提取下一个候选源重试
        else 时长合格 (>= 60s 完整音频)
            Gate-->>Downloader: 门禁通过 (269.0s)
            Downloader->>FS: 原子移动至 <歌名 - 歌手>.<ext>
            Downloader->>FS: 同步写入同名 <歌名 - 歌手>.lrc
            Downloader-->>View: 下载状态更新为完成
            Downloader-->>User: 系统通知与 Finder 高亮
        end
    end
```

---

## 三、 详细规格与算法阈值

### 1. 平台枚举与元数据模型
```swift
enum MusicSourcePlatform: String, CaseIterable, Identifiable {
    case all = "全部"
    case netease = "网易云"
    case kugou = "酷狗"
    case kuwo = "酷我"
    case qq = "QQ音乐"
    
    var id: String { rawValue }
    var badgeColor: Color { ... }
}

struct SearchTrackItem: Identifiable, Equatable {
    let id: String           // 唯一标识 (例如 "netease_12345", "kugou_hash", "kuwo_rid")
    let numericId: Int       // 兼容纯数字 id
    let source: MusicSourcePlatform
    let title: String
    let artist: String
    let album: String
    let durationSeconds: Double
    let qualityTag: String    // "FLAC", "320K", "192K", "128K"
    let extraData: [String: String] // 存放 hash, album_id, rid 等解析参数
}
```

### 2. 多源并发搜索机制
- 使用 `DispatchGroup` 并发调度四大平台的搜索请求；
- 单个平台超时设置：`4.0s`，避免单源网络延迟拖慢整体响应；
- 各源结果合并时，优先展示通过歌手匹配与歌名精准度的高分项，打上对应平台彩色徽标；
- 在搜索界面顶部提供 `Picker("平台", selection: $selectedPlatform)`，可随时切换【全部】、【网易云】、【酷狗】、【酷我】。

### 3. 多平台直链解析与跨平台自动换源
- **网易云**：Meting 302 Location 捕获 ➔ Paugram 备用 ➔ 官方 CDN；
- **酷我**：`antiserver.kuwo.cn/anti.s?type=convert_url&rid={rid}&format=mp3&response=url`；
- **酷狗**：移动端直链 API 及 CDN 回退解析；
- **自定义 API**：支持在 `DownloadConfig` 中配置外部/自建解析 API 地址，享有最高解析优先级；
- **AntiPreviewGate 门禁保护**：所有下载的音频必须通过 `AVURLAsset` 物理时长校验（$\ge 60$ 秒且误差受控），试听残卷一律物理销毁并不中断流水线，自动无感触发跨平台换源轮询。
