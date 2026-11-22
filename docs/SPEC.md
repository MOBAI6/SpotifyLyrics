# SpotifyLyrics 法律合规防侵权与本地私有音源隔离规范 (SPEC)

针对用户指示：**“这种需要特殊源的可以隐藏掉，不上传git，也要注意下被别人起诉的点”**，本规范确立**开源代码库 100% 纯净中立化**、**法律避风港免责声明**、**本地私有音源隔离加载（Local Private Source Isolation）**与 **Git 敏感凭据防泄漏** 四大防线。

---

## 阶段一：业务全景泳道图 (Business Swimlane)

```mermaid
flowchart TD
    subgraph LegalCompliance["⚖️ 法律风险防御与代码库中立性 (Safe Harbor)"]
        L1["遵循避风港原则：SpotifyLyrics 定位为本地歌词与媒体管理中立框架"]
        L2["代码库 100% 纯净：严禁硬编码任何第三方未授权音源、逆向 API 或敏感域名"]
        L3["开源免责声明：明确不存储、不提供、不分发受版权保护音频"]
    end

    subgraph StorageIsolation["🔒 本地私有隔离层 (Local Private Isolation)"]
        S1["私有配置文件存放在用户受保护的本地目录 (~/.spotifylyrics/sources.json)"]
        S2[".gitignore 强制忽略所有 *sources*.json 与本地私有扩展"]
        S3["绝不纳入 Git 跟踪，绝不上传推送至公共代码仓库"]
    end

    subgraph RuntimeEngine["⚙️ 运行时动态加载器 (PrivateSourceLoader)"]
        R1["App 启动时动态探测本地私有配置是否存在"]
        R2{"本地是否存在私有音源配置?"}
        R3["已配置: 动态注入本地私有音源解析器 (享受全曲无损下载体验)"]
        R4["未配置: 保持标准公开开源接口，提示用户可按需外挂扩展"]
    end

    L1 & L2 --> S2
    S1 --> S2 --> S3
    S1 -.-> R1 --> R2
    R2 -- "是" --> R3
    R2 -- "否" --> R4
```

---

## 阶段二：技术架构时序图 (Technical Sequence)

```mermaid
sequenceDiagram
    autonumber
    actor Dev as 🧑‍💻 开发者 / 用户
    participant Git as 🐙 Git 版本控制 (.gitignore)
    participant LocalDisk as 💾 本地私有存储 (~/.spotifylyrics/)
    participant Loader as 🔌 PrivateSourceLoader
    participant App as 🖥️ SpotifyLyrics 运行时
    participant RemoteRepo as 🌐 GitHub 公开仓库

    rect rgb(245, 250, 255)
    Note over Dev, Git: 第一防线：本地私有隔离与 Git 阻断
    Dev->>LocalDisk: 生成 ~/.spotifylyrics/sources.json (配置真实接口与规则)
    Dev->>Git: 在 .gitignore 声明忽略 *sources*.json 与私有配置
    Git-->>RemoteRepo: Push 时拦截所有私有源配置文件 (零敏感泄漏)
    end

    rect rgb(255, 250, 240)
    Note over Loader, App: 第二防线：运行时纯代码动态挂载
    App->>Loader: loadPrivateSources()
    Loader->>LocalDisk: 读取本地私有 sources.json
    
    alt 本地配置存在且合法
        LocalDisk-->>Loader: 返回 endpoint / queryTemplate / extractRegex
        Loader-->>App: 动态注入本地专用 Master 优先解析通道 (用户本机丝滑生效)
    else 本地配置不存在
        Loader-->>App: 仅挂载公开基础通道，提供外挂音源导入入口
    end
    end
```

---

## 三、 详细规格与防线清单

### 1. 敏感特征代码彻底剥离
- `main.swift` 中严禁残留任何硬编码敏感音源 URL（如第三方未授权音源域名、商业逆向解析端点等）；
- 所有特殊音源均抽象为通用 `PrivateSourceRule` 模型：
  ```swift
  struct PrivateSourceRule: Codable {
      let enabled: Bool
      let name: String
      let endpoint: String
      let queryTemplate: String
      let extractRegex: String
      let preferFormat: String
  }
  ```

### 2. 本地私有隔离配置路径
- 配置文件优先读取：
  1. `~/.spotifylyrics/sources.json`
  2. `~/Library/Application Support/SpotifyLyrics/sources.json`
  3. 项目工作区根目录下受 `.gitignore` 保护的 `sources.local.json`
- `.gitignore` 强制包含：
  ```gitignore
  # Local private sources & extensions
  *sources.json
  *sources.local.json
  *.private.json
  .spotifylyrics/
  ```

### 3. 开源免责声明 (Disclaimer)
- 在 `README.md` 与状态栏“关于”菜单中常驻声明：
  > “免责声明：SpotifyLyrics 是一款基于开源协议开发的个人桌面歌词同步与本地媒体管理工具。本项目不提供、不分发任何受版权保护的音视频内容，亦不内置任何侵权音源接口。所有音频检索与解析能力均基于公开接口规范或由使用者自行配置的本地音源扩展提供，使用者应自行确保音源来源之合规性，与本项目开发者无关。”
