# TdGram

鸿蒙（HarmonyOS / OpenHarmony）原生 Telegram 第三方客户端。界面用 ArkTS/ArkUI，协议层用官方 [TDLib](https://github.com/tdlib/td)（C++），通过 NAPI 桥接。

_个人项目，与 Telegram 和华为无关。_

## 功能

- 手机号 + 验证码登录、两步验证密码、扫码登录
- 聊天列表（置顶、未读数、头像），下拉加载更多
- 消息列表：文字、图片、文件，向上滚动加载历史
- 发送文字、图片、文件；长按消息回复，点击引用跳转到原消息
- 图片全屏查看（双指缩放、双击还原），文件下载并保存到本机

## 结构

- `entry/src/main/cpp/napi_init.cpp`：TDLib JSON 接口的 NAPI 桥接。后台线程调用 `td_receive`，批量交给 JS 线程。另含二维码编码（[nayuki/QR-Code-generator](https://github.com/nayuki/QR-Code-generator)，MIT）
- `entry/src/main/ets/td/TdClient.ets`：请求/响应配对（`@extra`）和更新分发
- `entry/src/main/ets/td/Store.ets`：登录状态机、聊天列表、消息、文件下载
- `entry/src/main/ets/pages/`：登录、聊天列表、聊天页

## 构建

1. 交叉编译 TDLib（需要 Docker 和 OpenHarmony NDK）：

   ```bash
   docker run --rm --network host -v $PWD:/src:ro -v $PWD/build-td:/work -v /path/to/ohos-sdk/12/native:/ohos-native:ro ubuntu:22.04 bash -c '
     apt-get update -qq && apt-get install -y -qq gperf cmake g++ make perl curl ca-certificates zlib1g-dev libssl-dev git >/dev/null
     git clone --depth 1 https://github.com/tdlib/td.git /work/td
     cp /src/scripts/build-tdlib-ohos.sh /work/ && JOBS=8 /work/build-tdlib-ohos.sh'
   ```

   产物在 `build-td/out/arm64-v8a/td/lib/libtdjson.so`。把它的 SONAME 改成 `libtdjson.so`，复制到 `entry/libs/arm64-v8a/`。

2. 复制 `entry/src/main/ets/common/Config.template.ets` 为 `Config.ets`，填写在 <https://my.telegram.org/apps> 申请的 `api_id` 和 `api_hash`。

3. 用 DevEco Studio 打开并签名运行，或用命令行（OpenHarmony SDK API 12、hvigor 5.x、Java 17）：

   ```bash
   echo "sdk.dir=/path/to/ohos-sdk" > local.properties
   node node_modules/@ohos/hvigor/bin/hvigor.js --mode module \
     -p module=entry@default -p product=default -p buildMode=release assembleHap --no-daemon
   ```

## 限制

- 没有推送通知：App 退到后台被系统冻结后收不到新消息
- 不支持语音、视频通话和私密聊天
- 视频、贴纸、语音等只显示为文字占位
- 只有 arm64-v8a

## 许可

Apache-2.0。TDLib 为 BSL-1.0，静态链接的 OpenSSL 为 Apache-2.0，二维码编码器为 MIT。
