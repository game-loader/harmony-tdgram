# TdGram

鸿蒙（HarmonyOS / OpenHarmony）原生 Telegram 第三方客户端。界面用 ArkTS/ArkUI，协议层用官方 [TDLib](https://github.com/tdlib/td)（C++），通过 NAPI 桥接。

_个人项目，与 Telegram 和华为无关。_

## 功能

**消息类型**：文字（粗体、斜体、代码、链接、提及、剧透等格式）、图片、视频、GIF、视频消息（圆形）、语音、音乐、文件、贴纸（WEBP 静态、TGS 动画、WEBM 视频）、投票、位置、联系人、骰子、通话记录、系统消息。

**聊天**：回复与跳转原消息、编辑、删除（仅自己或所有人）、转发（可隐藏来源）、多选、置顶消息、表情回应、投票、机器人按钮、消息内搜索、日期分隔、已读双勾、“正在输入”、Markdown 发送、静默发送、草稿同步。

**媒体**：全屏查看器（左右切换、双指缩放、保存到图库）、语音按住录制（上滑取消，Opus 编码并生成波形）、语音播放（倍速、连续播放下一条、转文字）、批量发送图片和视频、阅后即焚图片、发送位置和投票、贴纸和 GIF 面板。

**私密聊天**：创建、端到端加密收发、状态提示、加密密钥图案比对。

**聊天列表**：文件夹标签、归档、置顶、静音、标为已读/未读、删除或退出、搜索聊天和全局消息、在线状态。

**Nicegram 风格功能**：多账号切换、幽灵模式（不发已读、不发输入状态、显示离线）、隐藏自己的手机号、显示用户和消息 ID、消息翻译、已登录设备管理、缓存清理。

**登录**：手机号 + 验证码、两步验证、二维码登录。

## 结构

- `entry/src/main/cpp/napi_init.cpp`：TDLib JSON 接口的 NAPI 桥接，后台线程批量接收；二维码编码（[nayuki/QR-Code-generator](https://github.com/nayuki/QR-Code-generator)，MIT）
- `entry/src/main/cpp/media.cpp`：Opus 语音解码为 WAV、录音编码为 Ogg/Opus 并生成 Telegram 波形、TGS 贴纸解压
- `entry/src/main/ets/td/`：`TdClient`（多客户端路由）、`Account`（单账号）、`Accounts`（多账号与设置）、`ChatStore`、`MessageStore`、`FileStore`、`Parse`
- `entry/src/main/ets/pages/`：登录、主页、聊天、媒体查看器、转发、资料、设置、联系人、投票、加密密钥
- TGS 动画贴纸用 `@ohos/lottie`（MIT，`third_party/lottie-2.0.38.har`）

## 构建

1. 交叉编译 TDLib（需要 Docker 和 OpenHarmony NDK）：

   ```bash
   docker run --rm --network host -v $PWD:/src:ro -v $PWD/build-td:/work -v /path/to/ohos-sdk/12/native:/ohos-native:ro ubuntu:22.04 bash -c '
     apt-get update -qq && apt-get install -y -qq gperf cmake g++ make perl curl ca-certificates zlib1g-dev libssl-dev git >/dev/null
     git clone --depth 1 https://github.com/tdlib/td.git /work/td
     cp /src/scripts/build-tdlib-ohos.sh /work/ && JOBS=8 /work/build-tdlib-ohos.sh'
   ```

   产物在 `build-td/out/arm64-v8a/td/lib/libtdjson.so`。把它的 SONAME 改成 `libtdjson.so`，复制到 `entry/libs/arm64-v8a/`。

2. 交叉编译 Ogg/Opus 静态库（下载 libogg 1.3.6、opus 1.5.2、opusfile 0.12、libopusenc 0.3 源码包并解压到同一目录）：

   ```bash
   NDK=/path/to/ohos-sdk/12/native SRC=/path/to/sources OUT=$PWD/entry/src/main/cpp/prebuilt/arm64-v8a scripts/build-audio-ohos.sh
   ```

   然后把 `third_party/lottie-2.0.38.har` 解压到 `entry/oh_modules/@ohos/lottie`（或用 ohpm install）。

3. 复制 `entry/src/main/ets/common/Config.template.ets` 为 `Config.ets`，填写在 <https://my.telegram.org/apps> 申请的 `api_id` 和 `api_hash`。

4. 用 DevEco Studio 打开并签名运行，或用命令行（OpenHarmony SDK API 12、hvigor 5.x、Java 17）：

   ```bash
   echo "sdk.dir=/path/to/ohos-sdk" > local.properties
   node node_modules/@ohos/hvigor/bin/hvigor.js --mode module \
     -p module=entry@default -p product=default -p buildMode=release assembleHap --no-daemon
   ```

## 限制

- 没有推送通知：通知只在 App 运行时发出，退到后台被系统冻结后收不到
- 不支持语音和视频通话、直播、Stories
- 自定义表情（Premium）显示为普通文字
- 只有 arm64-v8a

## 许可

Apache-2.0。TDLib 为 BSL-1.0，OpenSSL 为 Apache-2.0，libogg/opus/opusfile/libopusenc 为 BSD-3-Clause，二维码编码器和 lottie 为 MIT。
