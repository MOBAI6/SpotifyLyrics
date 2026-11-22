# SpotifyLyrics 音频防试听门禁与精准歌手匹配规范 (SPEC)

本文档针对**“下载仅十几秒试听片段”**与**“歌名对上但歌手不符”**的痛点，制定**音频真实时长物理门禁**、**歌手+歌名+时长三维置信度评分匹配**与**候选换源自动重试**的完整技术规范。

---

## 阶段一：业务全景泳道图 (Business Swimlane)

```mermaid
flowchart TD
    subgraph User["👤 用户交互 (User)"]
        A1["触发下载当前歌曲 (⌘S) 或搜索曲目下载"]
        A2["收到系统完成通知并在音乐目录查收完整正曲与LRC"]
        A3["若仅有试听片段且换源均失败，收到诚实明确的失败提示"]
    end

    subgraph CandidateRanker["🎯 候选集三维精准评分器 (Candidate Ranker)"]
        B1["获取目标曲目 (Title, Artist, TargetDuration)"]
        B2["全网搜索多条候选曲目 (15~20首)"]
        B3["歌手强匹配校验：清洗歌手名，非目标歌手一票否决剔除"]
        B4["过滤翻唱/伴奏/变奏噪音 (Cover / DJ / 伴奏 惩罚扣分)"]
        B5["时长容差评分 (|候选时长 - 目标时长| <= 5s 加分)"]
        B6["输出高置信度候选队列 (按总分从高到低排序)"]
    end

    subgraph DownloadPipeline["⚙️ 换源下载与防试听门禁 (Anti-Preview Gate)"]
        C1["依次取出得分最高的候选歌曲"]
        C2["三通道解析音频直链并异步流式下载至临时文件"]
        C3{"【物理时长门禁】\nAVURLAsset 读取真实音频时长\n1. 真实时长 >= 60s?\n2. 与目标时长比对误差 <= 15s?"}
        C4["判定为 VIP 试听残卷 (十几秒/30s)\n立即清理临时文件"]
        C5{"队列中是否还有其他高分候选?"}
        C6["判定为完整正曲！\n魔数格式校验与落盘 (~/Downloads/Music)"]
        C7["同步拉取/写入同名 .lrc 歌词并完成归档"]
    end

    A1 --> B1 --> B2 --> B3 --> B4 --> B5 --> B6
    B6 --> C1 --> C2 --> C3
    C3 -- "不满足 (仅十几秒试听)" --> C4 --> C5
    C5 -- "有其他候选" --> C1
    C5 -- "无其他候选" --> A3
    C3 -- "满足 (完整正曲)" --> C6 --> C7 --> A2
```

---

## 阶段二：技术架构时序图 (Technical Sequence)

```mermaid
sequenceDiagram
    autonumber
    actor User as 👤 用户
    participant VM as 🧠 LyricViewModel
    participant Engine as ⚙️ SongDownloadEngine
    participant Scorer as 🎯 MultiFactorScorer
    participant RemoteAPI as 🌐 音乐接口 (Meting/Paugram)
    participant AudioInspector as 🔍 AVURLAsset 时长探测器
    participant FS as 💾 本地文件系统 (Music Dir)

    User->>VM: 触发下载 (⌘S / 搜索下载)
    VM->>Engine: downloadTrack(title, artist, targetDuration)
    Engine->>RemoteAPI: 检索前 20 条候选列表
    RemoteAPI-->>Engine: 返回候选集

    rect rgb(245, 248, 255)
    Note over Engine, Scorer: 阶段一：歌手+歌名+时长三维评分
    Engine->>Scorer: rankCandidates(targetTitle, targetArtist, targetDuration)
    Scorer->>Scorer: 1. 歌手包含度检测 (非目标歌手直接剔除)
    Scorer->>Scorer: 2. 负面词降权 (Cover, 翻唱, DJ, 伴奏)
    Scorer->>Scorer: 3. 时长逼近加分 (|Δt| <= 5s)
    Scorer-->>Engine: 返回有序高分队列 candidatesQueue [C1, C2, C3...]
    end

    rect rgb(255, 250, 240)
    Note over Engine, AudioInspector: 阶段二：带防试听门禁的换源下载循环
    loop 遍历高分候选 (直至命中完整版)
        Engine->>RemoteAPI: 请求候选 Ci 音频直链
        RemoteAPI-->>Engine: 返回音频流
        Engine->>FS: 下载到临时文件 tempURL
        Engine->>AudioInspector: AVURLAsset(url: tempURL).duration
        AudioInspector-->>Engine: 真实时长 actualSeconds

        alt actualSeconds < 60s 或 |actualSeconds - targetDuration| > 20s
            Note over Engine: 触发防试听门禁：拦截 15s/30s 试听残卷！
            Engine->>FS: 物理删除 tempURL (即测即删)
            Note over Engine: 继续尝试下一首候选 C(i+1)
        else 真实时长合格 (>= 60s 且匹配正曲)
            Note over Engine: 门禁放行！真实完整音频确认
            Engine->>FS: 原子移动至目标目录: <安全歌名 - 安全歌手>.<ext>
            Engine->>FS: 并发拉取并写入同名 <安全歌名 - 安全歌手>.lrc
            Engine-->>VM: 回调成功，高亮 Finder 并触发系统通知
        end
    end
    end
```

---

## 三、 详细规格与算法阈值

### 1. 歌手与候选集评分公式 (Multi-Factor Scoring)
- **歌手纯净相似度 (Artist Score, 满分 50 分)**：
  - 清洗规则：去除 `(`、`)`、`feat.`、`ft.`、`with` 后缀，转小写与简体；
  - 匹配判定：若目标歌手完全出现在候选歌手字段中，得分 `50`；
  - **白名单一票否决制**：若候选歌手列表与目标歌手没有任何交集（例如目标为“周杰伦”，候选为“翻唱小周”），得分为 `-999`，**直接从候选队列中丢弃**。
- **歌名纯净度与负面标签过滤 (Title Score, 满分 30 分)**：
  - 目标歌名与候选歌名完全一致：`30` 分；
  - 负面词过滤：若目标曲名本身不含“翻唱/伴奏/cover/dj”，而候选词包含以下词汇：
    - `["翻唱", "cover", "伴奏", "inst", "instrumental", "dj版", "钢琴版", "吉他版", "remix", "纯音乐"]`
    - 每命中一个强扣 `30` 分，确保原唱正版排在最前。
- **时长逼近评分 (Duration Score, 满分 20 分)**：
  - 时长差 $|D_{cand} - D_{target}| \le 3$ 秒：`20` 分；
  - 时长差 $\le 8$ 秒：`10` 分；
  - 时长差 $> 30$ 秒：`-30` 分。
- **入选门槛**：仅总分 $\ge 60$ 分的曲目才允许进入下载尝试队列。

### 2. 真实音频物理时长门禁 (Anti-Preview Gate)
- **判定时机**：文件下载完成后、重命名归档前；
- **判定方法**：使用 `AVURLAsset(url: tempURL)` 读取实际音轨物理时长；
- **判定规则**：
  1. **绝对下限**：`actualDuration >= 60.0` 秒（任何只有十几秒、30秒的残片一律拦截）；
  2. **相对容差**：若目标歌曲时长已知（$T_{target} > 30$ 秒）：
     - 要求 $|actualDuration - T_{target}| \le 18.0$ 秒（或时长比率在 $85\% \sim 115\%$ 之间）；
  3. **拦截动作**：若判定为试听残卷，立即执行 `FileManager.default.removeItem(at: tempURL)`，并自动进入下一首候选换源重试；
  4. **全试听兜底**：若所有公开源版本均只有试听残卷，向用户明确反馈错误，严禁以残卷充当完成。
