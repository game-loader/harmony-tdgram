# TdGram

鸿蒙（HarmonyOS / OpenHarmony）原生 Telegram 第三方客户端。界面用 ArkTS/ArkUI，协议层用官方 [TDLib](https://github.com/tdlib/td)（C++），通过 NAPI 桥接。

_个人项目，与 Telegram 和华为无关。_

## 功能

**消息类型**：文字（粗体、斜体、代码、链接、提及、剧透等格式）、图片、视频、GIF、视频消息（圆形）、语音、音乐、文件、贴纸（WEBP 静态、TGS 动画、WEBM 视频）、投票、位置、联系人、骰子、通话记录、系统消息。

**聊天**：回复与跳转原消息、编辑、删除（仅自己或所有人）、转发（可隐藏来源）、多选、置顶消息、表情回应、投票、机器人按钮、日期分隔、已读双勾、“正在输入”、Markdown 发送、静默发送、草稿同步、链接预览卡片、话题群组。打开聊天时定位到第一条未读并显示“未读消息”分隔线，按实际看到的位置标记已读。频道帖子的评论和群里的回复串可以单独打开；向左滑动消息即可回复；发送失败的消息可以重试；可以跳转到指定日期；有未读的 @ 提及时显示跳转按钮。

**输入**：输入 `@` 列出群成员（没有用户名的成员也能提及），输入 `/` 列出机器人命令；机器人的回复键盘和“开始”按钮；多选投票；从其他窗口把图片、视频、文件、文字拖进聊天。

**搜索与标签**：聊天内搜索以结果面板显示，点击结果跳转并高亮，面板保持打开可连续跳转。点击消息里的 `#标签` 直接列出本聊天所有带该标签的消息。

**媒体**：全屏查看器（左右切换、双指缩放、保存到图库）、语音按住录制（上滑取消，Opus 编码并生成波形）、语音播放（迷你播放条、倍速、连续播放下一条、转文字）、多张图片和视频按相册发送、拍照和录像、阅后即焚图片、发送位置和投票、贴纸和 GIF 面板。资料页可查看聊天里的媒体、文件、链接、语音和群成员。

**折叠屏与大屏**（按 Huawei Pura X Max 调整）：展开后左边聊天列表、右边内容，资料、设置、联系人、转发等页面也在右栏打开；合上后同一组页面变成单栏，滚动位置、草稿和已打开的页面都保留。分隔条可以拖动（靠近折痕时吸附，双击恢复默认），气泡、图片、贴纸面板和附件菜单按栏宽调整，键盘弹出时压缩布局而不是把标题栏顶出屏幕。设置里可以把分栏改成自动、始终或关闭。

**外观与网络**：深色模式（跟随系统或手动）、SOCKS5 / HTTP / MTProto 代理（登录前也能设置，支持测速和 t.me 代理链接）、连接状态提示。

**私密聊天**：创建、端到端加密收发、状态提示、加密密钥图案比对。

**聊天列表**：文件夹标签（带未读数）、归档、置顶、静音、标为已读/未读、删除或退出、搜索聊天和全局消息、在线状态；向左滑动一行可快速已读、置顶、归档；桌面图标显示未读数。

**Nicegram 风格功能**：多账号切换、幽灵模式（不发已读、不发输入状态、显示离线）、隐藏自己的手机号、显示用户和消息 ID、消息翻译、已登录设备管理、缓存清理。

**登录**：手机号 + 验证码、两步验证、二维码登录。

## 结构

- `entry/src/main/cpp/napi_init.cpp`：TDLib JSON 接口的 NAPI 桥接，后台线程批量接收；二维码编码（[nayuki/QR-Code-generator](https://github.com/nayuki/QR-Code-generator)，MIT）
- `entry/src/main/cpp/media.cpp`：Opus 语音解码为 WAV、录音编码为 Ogg/Opus 并生成 Telegram 波形、TGS 贴纸解压
- `entry/src/main/ets/td/`：`TdClient`（多客户端路由）、`Account`（单账号）、`Accounts`（多账号与设置）、`ChatStore`、`MessageStore`（每个打开的聊天一个实例）、`FileStore`、`Parse`
- `entry/src/main/ets/pages/`：登录、主页（聊天列表 + 右栏路由栈）、媒体查看器
- `entry/src/main/ets/panes/`：在右栏或全屏显示的页面：资料、设置、联系人、转发、投票、加密密钥、代理
- `entry/src/main/ets/common/`：`Layout`（分栏和尺寸规则）、`Nav`（路由栈）、`ListDiff`、`Tags`，都不依赖界面，有单元测试
- `tools/`：`build.sh`（测试 + 请求校验 + 构建）、`test.mjs`（单元测试）、`check-td.mjs`（对照 `td_api.tl` 检查代码里每个 TDLib 请求的类型名和字段名）
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
   tools/build.sh    # 单元测试、TDLib 请求校验，然后 hvigor assembleHap
   ```

   `check-td.mjs` 需要编译 TDLib 时用的 `td_api.tl`，可用 `--schema` 或环境变量 `TD_API_TL` 指定。

## 限制

- 没有推送通知：通知只在 App 运行时发出，退到后台被系统冻结后收不到
- 不支持语音和视频通话、直播、Stories
- 自定义表情（Premium）显示为普通文字
- 只有 arm64-v8a

## 许可

Apache-2.0。TDLib 为 BSL-1.0，OpenSSL 为 Apache-2.0，libogg/opus/opusfile/libopusenc 为 BSD-3-Clause，二维码编码器和 lottie 为 MIT。
