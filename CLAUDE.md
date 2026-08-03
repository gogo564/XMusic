# CLAUDE.md

本文件为 Claude Code 在本仓库工作时提供指引。

## 规则
1. 所有输出必须使用中文。

## 项目概述

XMusic 是一个基于 SwiftUI / SwiftData / AVFoundation 的 iOS 音乐播放器（fork 自 primitiver/xmusic），已改写为对接用户自己的 lx-sync-server（局域网音乐同步服务器）。支持核心播放、下载、以及服务器歌单同步（/api/data 的 defaultList / loveList / userList）。

## 构建命令

- **构建**：`xcodebuild -project XMusic.xcodeproj -scheme XMusic -configuration Debug build`
- **模拟器构建**：`xcodebuild -project XMusic.xcodeproj -scheme XMusic -destination 'platform=iOS Simulator,name=iPhone 16' build`
- **CI**：GitHub Actions（`.github/workflows/build.yml`）通过 XcodeGen 生成工程并做无签名 archive 打包 IPA。

## 架构

### 入口
- `Sources/XmusicApp.swift` — SwiftUI `@main` 入口。手动创建 `ModelContainer(for: RecentTrackEntity.self)`，把 `mainContext` 注入 `PlayerManager.shared.modelContext`，通过 `.modelContainer(modelContainer)` 提供给视图。`needsConfig` 控制首次配置页（SettingsView）。

### 数据层
- `Sources/LXSong.swift` — 歌曲模型（保留原始字典 `raw`，可回传服务器）。含 `LXPlaylist`、`LXOnlinePlaylist`、`LXListData`、`LXListKind`，以及 `LXSong.jsonData` / `init?(jsonData:)` 持久化辅助。
- `Sources/LXAPIClient.swift` — 与 lx-sync-server 通信的单例。提供 `login` / `search` / `getPlaybackURL` / `getLyric` / `getData` / `saveData` / `getLeaderBoards` / `getLeaderBoardSongs` / `getHotSearch` / `searchPlaylists` / `getSongListTags` / `getSongListByTag` / `getSongListDetail`。请求头 `x-frontend-auth` / `x-user-name` / `x-user-token`。
- `Sources/ServerConfig.swift` — `ServerConfig`（服务器地址/账号/密码/管理密码/音质）+ `AppConfigStore`（UserDefaults 持久化，含 token）。
- `Sources/PlaylistStore.swift` — 服务器歌单状态（defaultList/loveList/userList），增删改后调用 `saveData` 推回服务器。
- `Sources/LRCParser.swift` — LRC 歌词解析。

### 播放
- `Sources/PlayerManager.swift` — `AVPlayer` 封装。缓存优先（`MusicCacheManager`），否则调 `LXAPIClient.getPlaybackURL` + `getLyric`。队列/索引/歌曲持久化到 UserDefaults；播放时通过注入的 `modelContext` 写入最近播放（`RecentTrackEntity`）。支持锁屏控制（MPRemoteCommandCenter）。

### 视图（均在 `Sources/`）
- `ContentView.swift` — 3 Tab（推荐/搜索/我的）+ 底部迷你播放器 + 全屏 `PlayerView` sheet。
- `PlayerView.swift` — 全屏播放器：模糊封面 + 侧滑歌词、进度条、控制按钮、收藏（loveList）。
- `HomeView` / `SearchView` / `SongSearchResultsView` / `MiniPlayerView`（都在 ContentView.swift 内）。
- `RankCategoryView.swift` — 榜单分类 + `RankSongsView` 榜单歌曲。
- `PlaylistListView.swift` — 歌单广场（tag 筛选 + 分页）。
- `PlaylistDetailView.swift` — 在线歌单详情（服务器 songList API）。
- `ServerPlaylistDetailView.swift` — 服务器歌单详情（defaultList/loveList/userList，支持删除）。
- `RecentPlaylistView.swift` — 最近播放 sheet。
- `SongRow.swift` — 歌曲行（含下载/添加到歌单/音质菜单），内含 `QualityPickerView`。
- `PlaylistPickerView.swift` — 添加到歌单 sheet。
- `DownloadsView.swift` / `LibraryView.swift` / `SettingsView.swift` — 下载 / 我的 / 设置。

### 其他
- `Sources/MusicCacheManager.swift` — 音频文件缓存（Documents/MusicCache/）。
- `Sources/DownloadService.swift` — 下载服务（/api/music/download）。
- `Sources/LXCachedImage.swift` — 简单带缓存图片加载。
- `Sources/HapticManager.swift` — 触觉反馈。
- `Sources/MusicSources.swift` — 音源列表 `[("kw","酷我"),("wy","网易"),("tx","腾讯"),("kg","酷狗"),("mg","咪咕")]`。
- `Sources/RecentTrackEntity.swift` — 最近播放 SwiftData 模型（存 `rawJSON`，通过 `song` 还原 `LXSong`）。

## 关键约定
- 所有对服务器的请求都通过 `LXAPIClient`，token 由 `AppConfigStore` 管理。
- 最近播放统一由 `PlayerManager.startPlayback` / `loadLyric` 通过 `modelContext` 写入，视图无需单独保存。
- 音质在 `SettingsView` 和 `SongRow`（QualityPickerView）中可切换。

## 文件布局

```
Sources/
  XmusicApp.swift            # 入口 + ModelContainer
  ContentView.swift           # TabView/Home/Search/MiniPlayer
  PlayerView.swift            # 全屏播放器 + 歌词
  PlayerManager.swift         # 播放核心
  LXAPIClient.swift           # 服务器 API 客户端
  LXSong.swift                # 模型
  ServerConfig.swift          # 配置 + token
  PlaylistStore.swift         # 服务器歌单状态
  LRCParser.swift             # 歌词解析
  MusicCacheManager.swift     # 音频缓存
  DownloadService.swift       # 下载
  DownloadService... etc      # 其余视图
  Assets.xcassets/            # 图标、颜色
```
